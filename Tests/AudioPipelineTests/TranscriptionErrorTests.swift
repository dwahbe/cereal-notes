import Foundation
import Testing

@testable import SerialNotes

@Suite("Transcription Errors")
struct TranscriptionErrorTests {
    @Test("Repeated live ASR failures use a user-facing message")
    func repeatedLiveASRFailuresUseUserFacingMessage() {
        #expect(
            TranscriptionError.streamingTranscriptionDegraded.errorDescription
                == "Live transcription hit repeated model errors. Recording will continue, but the transcript may be incomplete."
        )
    }

    @Test("Core ML prediction failures are sanitized")
    func coreMLPredictionFailuresAreSanitized() {
        let rawError = NSError(
            domain: "com.apple.CoreML",
            code: 0,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Unable to compute the asynchronous prediction using ML Program. It can be an invalid input data or broken/unsupported model."
            ]
        )

        #expect(
            TranscriptionError.userFacingDescription(for: rawError)
                == TranscriptionError.streamingTranscriptionDegraded.localizedDescription
        )
    }
}
