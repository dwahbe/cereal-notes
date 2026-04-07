import Foundation

@MainActor @Observable
final class RecordingState {
    var isRecording = false
    var elapsedTime: TimeInterval = 0
    var errorMessage: String?

    private var timer: Timer?
    private var startDate: Date?
    private let captureService = AudioCaptureService()

    var formattedElapsedTime: String {
        let minutes = Int(elapsedTime) / 60
        let seconds = Int(elapsedTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func start(storageDirectory: URL) async {
        // Ensure any previous session is fully stopped
        await stopCapture()

        do {
            try await captureService.startCapture(storageDirectory: storageDirectory) { [weak self] error in
                Task { @MainActor in
                    self?.errorMessage = error.localizedDescription
                    await self?.stopCapture()
                }
            }
            isRecording = true
            errorMessage = nil
            startDate = Date()
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
            await stopCapture()
        }
    }

    private func stopCapture() async {
        await captureService.stopCapture()
    }
}
