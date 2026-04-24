import AVFoundation
import FluidAudio
import Foundation

actor TranscriptionService {
    // MARK: - Callbacks (set by RecordingState)

    /// Called when a transcription error occurs. Delivered off-main; caller hops to main if needed.
    var onError: (@Sendable (Error) -> Void)?

    /// Called with the current in-progress partial transcript for the mic stream.
    /// Empty string means "clear the live text" (after an utterance is finalized).
    var onMicPartial: (@Sendable (String) -> Void)?

    /// Called with the current in-progress partial transcript for the system-audio stream.
    var onSystemPartial: (@Sendable (String) -> Void)?

    func setCallbacks(
        onError: (@Sendable (Error) -> Void)?,
        onMicPartial: (@Sendable (String) -> Void)?,
        onSystemPartial: (@Sendable (String) -> Void)?
    ) {
        self.onError = onError
        self.onMicPartial = onMicPartial
        self.onSystemPartial = onSystemPartial
    }

    // MARK: - FluidAudio components

    private var micAsr: StreamingEouAsrManager?
    private var systemAsr: StreamingEouAsrManager?
    private var systemDiarizer: LSEENDDiarizer?
    private var micDiarizer: LSEENDDiarizer?

    // MARK: - Session state

    private var transcriptHandle: FileHandle?
    private var sessionStart: Date?
    private var sessionDate: Date?

    private var micSamplesProcessed: Int = 0
    private var systemSamplesProcessed: Int = 0
    private var micSampleRate: Double = 0
    private var systemSampleRate: Double = 0

    // Utterance boundaries (sample-count at time EOU fired) — used to estimate
    // utterance midpoints for diarizer lookup instead of biasing toward EOU time.
    private var lastMicUtteranceEndSamples: Int = 0
    private var lastSystemUtteranceEndSamples: Int = 0

    // Speaker label maps, keyed separately for mic vs system so indexes don't collide.
    private var systemSpeakerLabels: [Int: String] = [:]
    private var micSpeakerLabels: [Int: String] = [:]
    private var nextSystemPersonNumber = 1
    private var micSeenPrimarySpeaker = false
    private var nextMicVoiceNumber = 2

    private var pendingEntries: [TranscriptEntry] = []
    private static let flushDelaySeconds: TimeInterval = 3.0

    private var modelsLoaded = false

    // MARK: - Model Lifecycle

    func downloadModelsIfNeeded() async throws {
        guard !modelsLoaded else { return }

        let micManager = StreamingEouAsrManager()
        let sysManager = StreamingEouAsrManager()
        try await micManager.loadModels()
        try await sysManager.loadModels()

        let sysDia = LSEENDDiarizer()
        try await sysDia.initialize()
        let micDia = LSEENDDiarizer()
        try await micDia.initialize()

        micAsr = micManager
        systemAsr = sysManager
        systemDiarizer = sysDia
        micDiarizer = micDia
        modelsLoaded = true
    }

    // MARK: - Session Lifecycle

    func startSession(
        sessionDirectory: URL,
        sessionStart: Date,
        enrollments: [EnrollmentClip] = []
    ) async throws {
        guard modelsLoaded else {
            throw TranscriptionError.modelsNotLoaded
        }

        await micAsr?.reset()
        await systemAsr?.reset()
        systemDiarizer?.reset()
        micDiarizer?.reset()

        // Prime diarizers with saved voice profiles so known speakers get named.
        for clip in enrollments {
            let diarizer: LSEENDDiarizer?
            switch clip.side {
            case .mic: diarizer = micDiarizer
            case .system: diarizer = systemDiarizer
            }
            do {
                _ = try diarizer?.enrollSpeaker(
                    withSamples: clip.samples,
                    sourceSampleRate: clip.sampleRate,
                    named: clip.name
                )
            } catch {
                // Priming is best-effort — a bad clip shouldn't block the session.
                onError?(error)
            }
        }

        self.sessionStart = sessionStart
        self.sessionDate = sessionStart
        micSamplesProcessed = 0
        systemSamplesProcessed = 0
        micSampleRate = 0
        systemSampleRate = 0
        lastMicUtteranceEndSamples = 0
        lastSystemUtteranceEndSamples = 0
        systemSpeakerLabels = [:]
        micSpeakerLabels = [:]
        nextSystemPersonNumber = 1
        micSeenPrimarySpeaker = false
        nextMicVoiceNumber = 2
        pendingEntries = []

        let transcriptURL = sessionDirectory.appendingPathComponent("transcript.md")
        FileManager.default.createFile(atPath: transcriptURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: transcriptURL)
        transcriptHandle = handle

        // Write placeholder header with duration=0. Rewritten on endSession
        // with final duration — header byte-length is fixed, so seek+write works.
        let header = TranscriptFormatter.header(date: sessionStart, duration: 0)
        handle.write(Data(header.utf8))

        // ASR callbacks
        await micAsr?.setEouCallback { [weak self] text in
            guard let self else { return }
            Task { await self.handleMicUtterance(text) }
        }
        await micAsr?.setPartialCallback { [weak self] text in
            guard let self else { return }
            Task { await self.forwardMicPartial(text) }
        }
        await systemAsr?.setEouCallback { [weak self] text in
            guard let self else { return }
            Task { await self.handleSystemUtterance(text) }
        }
        await systemAsr?.setPartialCallback { [weak self] text in
            guard let self else { return }
            Task { await self.forwardSystemPartial(text) }
        }
    }

    func endSession() async {
        // Flush any audio sitting in the ASR buffers into one last utterance each
        do {
            if let micText = try await micAsr?.finish(), !micText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let midpoint = midpointTime(
                    lastEndSamples: lastMicUtteranceEndSamples,
                    currentSamples: micSamplesProcessed,
                    sampleRate: micSampleRate
                )
                let speaker = currentMicSpeaker(at: midpoint)
                pendingEntries.append(TranscriptEntry(speaker: speaker, text: micText, timestamp: midpoint))
            }
        } catch {
            onError?(error)
        }
        do {
            if let sysText = try await systemAsr?.finish(), !sysText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let midpoint = midpointTime(
                    lastEndSamples: lastSystemUtteranceEndSamples,
                    currentSamples: systemSamplesProcessed,
                    sampleRate: systemSampleRate
                )
                let speaker = currentSystemSpeaker(at: midpoint)
                pendingEntries.append(TranscriptEntry(speaker: speaker, text: sysText, timestamp: midpoint))
            }
        } catch {
            onError?(error)
        }

        _ = try? systemDiarizer?.finalizeSession()
        _ = try? micDiarizer?.finalizeSession()

        flushAllEntries()

        // Rewrite header with real duration
        if let handle = transcriptHandle, let start = sessionStart {
            let duration = Date().timeIntervalSince(start)
            let finalHeader = TranscriptFormatter.header(date: sessionDate ?? start, duration: duration)
            do {
                try handle.seek(toOffset: 0)
                handle.write(Data(finalHeader.utf8))
            } catch {
                onError?(error)
            }
        }

        try? transcriptHandle?.close()
        transcriptHandle = nil
        sessionStart = nil
        sessionDate = nil

        // Clear any lingering live partials on consumers
        onMicPartial?("")
        onSystemPartial?("")
    }

    // MARK: - Audio Input

    func processMicAudio(_ samples: [Float], sampleRate: Double) async {
        guard let asr = micAsr else { return }
        if micSampleRate == 0 { micSampleRate = sampleRate }
        guard let buffer = makePCMBuffer(samples: samples, sampleRate: sampleRate) else { return }

        micSamplesProcessed += samples.count

        do {
            _ = try await asr.process(audioBuffer: buffer)
        } catch {
            onError?(error)
        }

        if let diarizer = micDiarizer {
            do {
                try diarizer.addAudio(samples, sourceSampleRate: sampleRate)
                _ = try diarizer.process()
            } catch {
                onError?(error)
            }
        }
    }

    func processSystemAudio(_ samples: [Float], sampleRate: Double) async {
        guard let asr = systemAsr else { return }
        if systemSampleRate == 0 { systemSampleRate = sampleRate }
        guard let buffer = makePCMBuffer(samples: samples, sampleRate: sampleRate) else { return }

        systemSamplesProcessed += samples.count

        do {
            _ = try await asr.process(audioBuffer: buffer)
        } catch {
            onError?(error)
        }

        if let diarizer = systemDiarizer {
            do {
                try diarizer.addAudio(samples, sourceSampleRate: sampleRate)
                _ = try diarizer.process()
            } catch {
                onError?(error)
            }
        }
    }

    // MARK: - EOU Handlers

    private func handleMicUtterance(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // EOU fires once per session unless we reset — do this even on empty text.
        if !trimmed.isEmpty {
            let midpoint = midpointTime(
                lastEndSamples: lastMicUtteranceEndSamples,
                currentSamples: micSamplesProcessed,
                sampleRate: micSampleRate
            )
            let speaker = currentMicSpeaker(at: midpoint)
            pendingEntries.append(TranscriptEntry(speaker: speaker, text: trimmed, timestamp: midpoint))
            flushOldEntries()
        }

        lastMicUtteranceEndSamples = micSamplesProcessed
        onMicPartial?("")
        await micAsr?.reset()
    }

    private func handleSystemUtterance(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmed.isEmpty {
            let midpoint = midpointTime(
                lastEndSamples: lastSystemUtteranceEndSamples,
                currentSamples: systemSamplesProcessed,
                sampleRate: systemSampleRate
            )
            let speaker = currentSystemSpeaker(at: midpoint)
            pendingEntries.append(TranscriptEntry(speaker: speaker, text: trimmed, timestamp: midpoint))
            flushOldEntries()
        }

        lastSystemUtteranceEndSamples = systemSamplesProcessed
        onSystemPartial?("")
        await systemAsr?.reset()
    }

    private func forwardMicPartial(_ text: String) {
        onMicPartial?(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func forwardSystemPartial(_ text: String) {
        onSystemPartial?(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Speaker Lookup

    private func currentSystemSpeaker(at time: TimeInterval) -> String {
        guard let diarizer = systemDiarizer else {
            return labelForSystemSpeaker(0)
        }
        if let (idx, name) = speakerInfo(in: diarizer, at: time) {
            if let name, !name.isEmpty { return name }
            return labelForSystemSpeaker(idx)
        }
        return labelForSystemSpeaker(0)
    }

    private func currentMicSpeaker(at time: TimeInterval) -> String {
        guard let diarizer = micDiarizer else {
            return labelForMicSpeaker(0)
        }
        if let (idx, name) = speakerInfo(in: diarizer, at: time) {
            if let name, !name.isEmpty { return name }
            return labelForMicSpeaker(idx)
        }
        return labelForMicSpeaker(0)
    }

    /// Find the diarizer's best guess of who was speaking at `time`, along with
    /// the enrolled name if one was primed at session start.
    /// Preference: segment covering time → most recently ended segment.
    private nonisolated func speakerInfo(in diarizer: LSEENDDiarizer, at time: TimeInterval) -> (index: Int, name: String?)? {
        let timeline = diarizer.timeline
        let timeFloat = Float(time)

        for (_, speaker) in timeline.speakers {
            for segment in speaker.finalizedSegments + speaker.tentativeSegments {
                if segment.startTime <= timeFloat && timeFloat <= segment.endTime {
                    return (segment.speakerIndex, speaker.name)
                }
            }
        }

        var bestMatch: (index: Int, name: String?, endTime: Float)?
        for speaker in timeline.speakers.values {
            for segment in speaker.finalizedSegments + speaker.tentativeSegments
            where segment.endTime <= timeFloat {
                if bestMatch == nil || segment.endTime > bestMatch!.endTime {
                    bestMatch = (segment.speakerIndex, speaker.name, segment.endTime)
                }
            }
        }
        return bestMatch.map { ($0.index, $0.name) }
    }

    private func labelForSystemSpeaker(_ speakerIndex: Int) -> String {
        if let label = systemSpeakerLabels[speakerIndex] { return label }
        let label = "Person \(nextSystemPersonNumber)"
        nextSystemPersonNumber += 1
        systemSpeakerLabels[speakerIndex] = label
        return label
    }

    /// First mic speaker encountered → "You". Additional mic speakers → "Voice 2", "Voice 3", …
    private func labelForMicSpeaker(_ speakerIndex: Int) -> String {
        if let label = micSpeakerLabels[speakerIndex] { return label }
        let label: String
        if !micSeenPrimarySpeaker {
            label = "You"
            micSeenPrimarySpeaker = true
        } else {
            label = "Voice \(nextMicVoiceNumber)"
            nextMicVoiceNumber += 1
        }
        micSpeakerLabels[speakerIndex] = label
        return label
    }

    // MARK: - Transcript Flushing

    private func flushOldEntries() {
        guard let latest = pendingEntries.map(\.timestamp).max() else { return }
        let cutoff = latest - Self.flushDelaySeconds

        let ready = pendingEntries.filter { $0.timestamp <= cutoff }.sorted()
        pendingEntries.removeAll { $0.timestamp <= cutoff }

        writeEntries(ready)
    }

    private func flushAllEntries() {
        let sorted = pendingEntries.sorted()
        pendingEntries.removeAll()
        writeEntries(sorted)
    }

    private func writeEntries(_ entries: [TranscriptEntry]) {
        guard let handle = transcriptHandle else { return }
        for entry in entries {
            let line = TranscriptFormatter.entry(
                speaker: entry.speaker,
                timestamp: entry.timestamp,
                text: entry.text
            )
            handle.write(Data(line.utf8))
        }
    }

    // MARK: - Helpers

    private nonisolated func midpointTime(
        lastEndSamples: Int,
        currentSamples: Int,
        sampleRate: Double
    ) -> TimeInterval {
        guard sampleRate > 0 else { return 0 }
        let midSample = (lastEndSamples + currentSamples) / 2
        return TimeInterval(midSample) / sampleRate
    }

    private nonisolated func makePCMBuffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }
}

// MARK: - Supporting Types

private struct TranscriptEntry: Comparable {
    let speaker: String
    let text: String
    let timestamp: TimeInterval

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.timestamp < rhs.timestamp
    }
}

enum TranscriptionError: LocalizedError {
    case modelsNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelsNotLoaded:
            return "Transcription models have not been downloaded yet."
        }
    }
}

/// A single voice enrollment, handed to the transcription service at session start
/// so the diarizer can label matching voices by name instead of "Person N" / "You".
struct EnrollmentClip: Sendable {
    enum Side: Sendable { case mic, system }
    let name: String
    let side: Side
    let samples: [Float]
    let sampleRate: Double
}
