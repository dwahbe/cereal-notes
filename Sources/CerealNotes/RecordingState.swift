import Foundation

@MainActor @Observable
final class RecordingState {
    var isRecording = false
    var elapsedTime: TimeInterval = 0

    private var timer: Timer?

    var formattedElapsedTime: String {
        let minutes = Int(elapsedTime) / 60
        let seconds = Int(elapsedTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func start() {
        isRecording = true
        elapsedTime = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.elapsedTime += 1
            }
        }
    }

    func stop() {
        isRecording = false
        timer?.invalidate()
        timer = nil
    }
}
