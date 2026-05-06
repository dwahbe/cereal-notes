import Foundation
import Testing

@testable import SerialNotes

@Suite("Transcript Echo Suppression")
struct TranscriptEchoSuppressionTests {
    @Test("Remote speech echoed into mic is detected")
    func remoteSpeechEchoedIntoMicIsDetected() {
        let systemContext = """
        Okay, now that you know who we work with, what does that mean for who we look for? In terms of basic eligibility requirements, you need a minimum of three years of work experience.
        """
        let micText = """
        now that you know who we work with what does that mean for who we look for in terms of basic eligibility requirements you need a minimum of three years of work experience
        """

        #expect(TranscriptTextProcessing.isLikelyEcho(micText: micText, systemContext: systemContext))
    }

    @Test("Short backchannels are not suppressed")
    func shortBackchannelsAreNotSuppressed() {
        #expect(!TranscriptTextProcessing.isLikelyEcho(
            micText: "great thank you",
            systemContext: "Great, thank you."
        ))
    }

    @Test("Distinct user speech is not suppressed")
    func distinctUserSpeechIsNotSuppressed() {
        let systemContext = """
        The application deadline is the eighteenth of May, and interviews happen in June after the first review stage.
        """
        let micText = """
        I had a question about whether the practical interview will focus on finance experience or general problem solving
        """

        #expect(!TranscriptTextProcessing.isLikelyEcho(micText: micText, systemContext: systemContext))
    }
}
