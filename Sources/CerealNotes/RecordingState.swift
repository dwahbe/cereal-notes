import Foundation

@MainActor @Observable
final class RecordingState {
    var isRecording = false
    var elapsedTime: TimeInterval = 0
    var errorMessage: String?

    /// In-progress partial text from the mic stream (what you're saying now).
    var livePartialMic: String = ""
    /// In-progress partial text from the system-audio stream (what the remote side is saying).
    var livePartialSystem: String = ""

    @ObservationIgnored var onRecordingChange: (@MainActor () -> Void)?
    @ObservationIgnored weak var voiceProfileStore: VoiceProfileStore?

    private var timer: Timer?
    private var startDate: Date?
    private var currentSessionDir: URL?
    private let captureService = AudioCaptureService()
    let transcriptionService = TranscriptionService()

    var formattedElapsedTime: String {
        let minutes = Int(elapsedTime) / 60
        let seconds = Int(elapsedTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func start(storageDirectory: URL) async {
        await stopCapture()

        do {
            // Idempotent — if models are already loaded this returns immediately.
            // If a download kicked off at app launch is still in flight, the
            // actor serializes us behind it so we don't race to re-download.
            try await transcriptionService.downloadModelsIfNeeded()

            let sessionDir = storageDirectory.appendingPathComponent(Self.sessionDirectoryName())
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

            // Wire transcription callbacks (errors + live partials).
            await transcriptionService.setCallbacks(
                onError: { [weak self] error in
                    Task { @MainActor in
                        self?.errorMessage = error.localizedDescription
                    }
                },
                onMicPartial: { [weak self] text in
                    Task { @MainActor in
                        self?.livePartialMic = text
                    }
                },
                onSystemPartial: { [weak self] text in
                    Task { @MainActor in
                        self?.livePartialSystem = text
                    }
                }
            )

            // Wire audio buffer callbacks for transcription.
            let transcriber = transcriptionService
            captureService.onSystemAudioBuffer = { samples, sampleRate in
                Task { await transcriber.processSystemAudio(samples, sampleRate: sampleRate) }
            }
            captureService.onMicAudioBuffer = { samples, sampleRate in
                Task { await transcriber.processMicAudio(samples, sampleRate: sampleRate) }
            }

            try await captureService.startCapture(sessionDir: sessionDir) { [weak self] error in
                Task { @MainActor in
                    self?.errorMessage = error.localizedDescription
                    await self?.stopCapture()
                }
            }

            let now = Date()
            let enrollments = loadEnrollments()
            try await transcriptionService.startSession(
                sessionDirectory: sessionDir,
                sessionStart: now,
                enrollments: enrollments
            )

            isRecording = true
            errorMessage = nil
            livePartialMic = ""
            livePartialSystem = ""
            startDate = now
            currentSessionDir = sessionDir
            elapsedTime = 0
            onRecordingChange?()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let startDate = self.startDate else { return }
                    self.elapsedTime = Date().timeIntervalSince(startDate)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        isRecording = false
        timer?.invalidate()
        timer = nil
        let sessionStart = startDate
        let sessionDir = currentSessionDir
        startDate = nil
        currentSessionDir = nil
        livePartialMic = ""
        livePartialSystem = ""
        onRecordingChange?()
        Task { [weak self] in
            guard let self else { return }
            await self.transcriptionService.endSession()
            let stats = self.captureService.currentStats()
            await self.stopCapture()
            self.finalizeSession(
                sessionDir: sessionDir,
                sessionStart: sessionStart,
                stats: stats
            )
        }
    }

    private func finalizeSession(
        sessionDir: URL?,
        sessionStart: Date?,
        stats: AudioCaptureStats
    ) {
        guard let sessionDir, let sessionStart else { return }

        writeSessionJSON(sessionDir: sessionDir, sessionStart: sessionStart, stats: stats)

        // Warn if the system-audio side didn't produce any buffers — usually a
        // TCC/permission problem (stale code signature after a rebuild). The
        // mic was probably fine so the transcript isn't empty, but it's
        // one-sided and the user should know.
        if stats.path == .processTap, stats.system.bufferCount == 0 {
            errorMessage = "System audio wasn't captured — only your mic was recorded. Check System Settings → Privacy & Security → System Audio Recording Only."
        }
    }

    private func writeSessionJSON(sessionDir: URL, sessionStart: Date, stats: AudioCaptureStats) {
        let payload = SessionDiagnostics(
            startedAt: sessionStart,
            endedAt: Date(),
            capturePath: stats.path?.rawValue ?? "unknown",
            mic: stats.mic,
            system: stats.system,
            enrolledProfiles: voiceProfileStore?.profiles.map { $0.name } ?? []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = sessionDir.appendingPathComponent("session.json")
        if let data = try? encoder.encode(payload) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private func stopCapture() async {
        await captureService.stopCapture()
    }

    private func loadEnrollments() -> [EnrollmentClip] {
        guard let store = voiceProfileStore else { return [] }
        return store.profiles.compactMap { profile -> EnrollmentClip? in
            guard let clip = store.loadClipSamples(for: profile) else { return nil }
            let side: EnrollmentClip.Side = profile.kind == .you ? .mic : .system
            return EnrollmentClip(
                name: profile.name,
                side: side,
                samples: clip.samples,
                sampleRate: clip.sampleRate
            )
        }
    }

    private static func sessionDirectoryName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}

/// Written as `session.json` alongside the WAVs so we can tell — after the
/// fact — which capture path was used, how much audio each stream got, and
/// which voice profiles were primed.
private struct SessionDiagnostics: Codable {
    let startedAt: Date
    let endedAt: Date
    let capturePath: String
    let mic: AudioStreamStats
    let system: AudioStreamStats
    let enrolledProfiles: [String]
}
