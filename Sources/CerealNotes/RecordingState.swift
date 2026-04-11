import Foundation

@MainActor @Observable
final class RecordingState {
    var isRecording = false
    var elapsedTime: TimeInterval = 0
    var errorMessage: String?

    private var timer: Timer?
    private var startDate: Date?
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
            let sessionDir = storageDirectory.appendingPathComponent(Self.sessionDirectoryName())
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

            // Wire up audio buffer callbacks for transcription
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
            try await transcriptionService.startSession(sessionDirectory: sessionDir, sessionStart: now)

            isRecording = true
            errorMessage = nil
            startDate = now
            elapsedTime = 0
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
        startDate = nil
        Task {
            await transcriptionService.endSession()
            await stopCapture()
        }
    }

    private func stopCapture() async {
        await captureService.stopCapture()
    }

    private static func sessionDirectoryName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}
