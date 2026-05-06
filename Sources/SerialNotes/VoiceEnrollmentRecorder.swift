import AVFoundation
import Foundation

/// Records a short clip of the user's voice for enrollment.
/// Writes mono float32 at the mic's native sample rate to a temp WAV file.
@MainActor @Observable
final class VoiceEnrollmentRecorder {
    enum State: Equatable {
        case idle
        case recording(elapsed: TimeInterval)
        case finished(clipURL: URL)
        case failed(String)
    }

    var state: State = .idle
    /// Smoothed 0…1 audio level updated during recording.
    var audioLevel: Float = 0

    /// Number of phrases the caller plans to prompt. The recorder advances to
    /// the next phrase each time it detects a trailing silence after speech,
    /// and finishes once all phrases have been spoken.
    var phraseCount: Int = 3
    /// Zero-based index of the phrase the user is currently expected to read.
    /// Advances on silence detection. When it reaches `phraseCount`, finish().
    var currentPhraseIndex: Int = 0

    /// Hard upper bound — if the mic stays silent or we never detect enough
    /// speech, we bail rather than holding the mic forever.
    var maxDurationSeconds: TimeInterval = 60

    /// Optional closures the caller wires so meeting detection doesn't false-fire
    /// while the enrollment recorder holds the mic.
    @ObservationIgnored var onSuspendDetection: (@MainActor () -> Void)?
    @ObservationIgnored var onResumeDetection: (@MainActor () -> Void)?

    private var engine: AVAudioEngine?
    private var writer: AudioFileWriter?
    private var timer: Timer?
    private var startDate: Date?
    private var detectionSuspended = false
    private var phraseState = PhraseDetectionState()

    /// Thresholds chosen to match the RMS normalization used by AudioFileWriter
    /// (which scales typical speech RMS to roughly 0.1–1.0).
    private let speakThreshold: Float = 0.10
    private let silenceThreshold: Float = 0.05
    private let minSpeechSecondsPerPhrase: TimeInterval = 1.0
    private let silenceHangoverSeconds: TimeInterval = 0.9

    func start() async {
        await stop()

        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else {
            state = .failed("Microphone permission denied")
            return
        }

        // Pause meeting detection before we bring the mic up, so we don't trigger
        // a phantom "meeting detected" banner from our own enrollment recording.
        onSuspendDetection?()
        detectionSuspended = true

        do {
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let hwFormat = inputNode.outputFormat(forBus: 0)
            guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
                resumeDetectionIfNeeded()
                state = .failed("Microphone unavailable")
                return
            }

            let tapFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: hwFormat.sampleRate,
                channels: 1,
                interleaved: false
            )!

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("enrollment-\(UUID().uuidString).wav")
            let audioFile = try AVAudioFile(
                forWriting: tempURL,
                settings: tapFormat.settings
            )
            let fileWriter = AudioFileWriter(file: audioFile)

            // The tap callback runs on the realtime audio thread. Closures
            // defined inside a @MainActor method inherit MainActor isolation —
            // Swift 6 then wraps them in a runtime check that traps (SIGTRAP)
            // when called off-main. We build the block from a nonisolated
            // helper so it carries no isolation, and it only touches the
            // lock-protected @unchecked-Sendable writer.
            inputNode.installTap(
                onBus: 0,
                bufferSize: 4096,
                format: tapFormat,
                block: Self.makeTapBlock(writer: fileWriter)
            )

            try engine.start()
            self.engine = engine
            self.writer = fileWriter

            startDate = Date()
            state = .recording(elapsed: 0)
            audioLevel = 0
            currentPhraseIndex = 0
            phraseState = PhraseDetectionState()

            let tickInterval: TimeInterval = 0.05
            timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let start = self.startDate else { return }
                    let elapsed = Date().timeIntervalSince(start)

                    // Pull the latest RMS from the writer (updated from the RT
                    // audio thread), smooth it, and publish for UI bindings.
                    if let level = self.writer?.takeLatestRMS() {
                        self.audioLevel = self.smooth(previous: self.audioLevel, target: level)
                    }

                    self.updatePhraseDetection(tickInterval: tickInterval)
                    self.state = .recording(elapsed: elapsed)

                    if elapsed >= self.maxDurationSeconds {
                        // Ran out of patience — bail rather than hold the mic.
                        Task { await self.bailWithTimeout() }
                    }
                }
            }
        } catch {
            resumeDetectionIfNeeded()
            state = .failed(error.localizedDescription)
        }
    }

    func cancel() async {
        await stop()
        state = .idle
        audioLevel = 0
    }

    private func finish() async {
        let clipURL = writer?.url
        await stop()
        if let clipURL {
            state = .finished(clipURL: clipURL)
        } else {
            state = .failed("Recording produced no clip")
        }
        audioLevel = 0
    }

    private func stop() async {
        timer?.invalidate()
        timer = nil
        startDate = nil

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        writer?.close()
        writer = nil

        resumeDetectionIfNeeded()
    }

    private func resumeDetectionIfNeeded() {
        guard detectionSuspended else { return }
        detectionSuspended = false
        onResumeDetection?()
    }

    private func updatePhraseDetection(tickInterval: TimeInterval) {
        // Already advanced past last phrase — waiting for finish() to fire.
        guard currentPhraseIndex < phraseCount else { return }

        if audioLevel > speakThreshold {
            phraseState.cumulativeSpeechSeconds += tickInterval
            phraseState.speechDetected = true
            phraseState.silenceStartedAt = nil
            return
        }

        guard audioLevel < silenceThreshold,
              phraseState.speechDetected,
              phraseState.cumulativeSpeechSeconds >= minSpeechSecondsPerPhrase
        else { return }

        if phraseState.silenceStartedAt == nil {
            phraseState.silenceStartedAt = Date()
            return
        }

        if let started = phraseState.silenceStartedAt,
           Date().timeIntervalSince(started) >= silenceHangoverSeconds {
            advancePhrase()
        }
    }

    private func advancePhrase() {
        currentPhraseIndex += 1
        phraseState = PhraseDetectionState()
        if currentPhraseIndex >= phraseCount {
            Task { await self.finish() }
        }
    }

    private func bailWithTimeout() async {
        await stop()
        state = .failed("We couldn't detect your voice. Please try again in a quieter spot.")
        audioLevel = 0
    }

    private func smooth(previous: Float, target: Float) -> Float {
        // Exponential moving average. Faster rise than fall so the meter feels
        // responsive to speech onset but decays visibly between phrases.
        let rise: Float = 0.6
        let fall: Float = 0.2
        let alpha = target > previous ? rise : fall
        return previous + (target - previous) * alpha
    }

    /// `nonisolated` so the returned closure does not inherit `@MainActor`
    /// from the surrounding class. Required for realtime audio tap callbacks.
    private nonisolated static func makeTapBlock(
        writer: AudioFileWriter
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            writer.ingest(buffer)
        }
    }
}

/// Per-phrase silence detection state, reset each time a phrase completes.
private struct PhraseDetectionState {
    var speechDetected = false
    var cumulativeSpeechSeconds: TimeInterval = 0
    var silenceStartedAt: Date?
}

/// Thread-safe audio file writer + level meter for RT audio tap callbacks.
/// Must be `@unchecked Sendable` because `AVAudioFile` isn't Sendable-annotated
/// — the `NSLock` provides the safety guarantee.
private final class AudioFileWriter: @unchecked Sendable {
    let url: URL
    private let file: AVAudioFile
    private let lock = NSLock()
    private var isClosed = false
    private var latestRMS: Float = 0

    init(file: AVAudioFile) {
        self.file = file
        self.url = file.url
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        let rms = Self.computeRMS(buffer)
        lock.withLock {
            guard !isClosed else { return }
            try? file.write(from: buffer)
            latestRMS = rms
        }
    }

    func takeLatestRMS() -> Float {
        lock.withLock {
            let value = latestRMS
            latestRMS = 0 // consume so the timer sees silence as it actually is
            return value
        }
    }

    func close() {
        lock.withLock { isClosed = true }
    }

    private static func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        var sumSquares: Float = 0
        for i in 0..<frames {
            let s = data[i]
            sumSquares += s * s
        }
        let rms = (sumSquares / Float(frames)).squareRoot()
        // Map typical speech RMS (~0.02–0.2) onto 0…1 with a gentle curve.
        let normalized = min(1.0, rms * 6.0)
        return normalized
    }
}
