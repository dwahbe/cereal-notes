import Foundation

@MainActor @Observable
final class ModelDownloadState {
    enum Status: Sendable {
        case notStarted
        case downloading
        case ready
        case failed(String)
    }

    var status: Status = .notStarted

    private let transcriptionService: TranscriptionService

    init(transcriptionService: TranscriptionService) {
        self.transcriptionService = transcriptionService
    }

    func downloadIfNeeded() async {
        guard case .notStarted = status else { return }
        status = .downloading
        do {
            try await transcriptionService.downloadModelsIfNeeded()
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
