import AVFoundation
import FluidAudio
import Foundation

actor TranscriptionService {
    private var micAsr: StreamingEouAsrManager?
    private var systemAsr: StreamingEouAsrManager?
    private var diarizer: LSEENDDiarizer?

    private var transcriptHandle: FileHandle?
    private var sessionStart: Date?

    // Track time offset for each stream (in samples at source sample rate)
    private var micSamplesProcessed: Int = 0
    private var systemSamplesProcessed: Int = 0
    private var micSampleRate: Double = 0
    private var systemSampleRate: Double = 0

    // Speaker index mapping: diarizer speakerIndex → "Person N" label
    private var speakerLabels: [Int: String] = [:]
    private var nextPersonNumber = 1

    // Buffer for chronological ordering across streams
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

        let dia = LSEENDDiarizer()
        try await dia.initialize()

        micAsr = micManager
        systemAsr = sysManager
        diarizer = dia
        modelsLoaded = true
    }

    // MARK: - Session Lifecycle

    func startSession(sessionDirectory: URL, sessionStart: Date) async throws {
        guard modelsLoaded else {
            throw TranscriptionError.modelsNotLoaded
        }

        await micAsr?.reset()
        await systemAsr?.reset()
        diarizer?.reset()

        self.sessionStart = sessionStart
        micSamplesProcessed = 0
        systemSamplesProcessed = 0
        micSampleRate = 0
        systemSampleRate = 0
        speakerLabels = [:]
        nextPersonNumber = 1
        pendingEntries = []

        let transcriptURL = sessionDirectory.appendingPathComponent("transcript.md")
        FileManager.default.createFile(atPath: transcriptURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: transcriptURL)
        transcriptHandle = handle

        let header = TranscriptFormatter.header(date: sessionStart)
        handle.write(Data(header.utf8))

        // Set up EOU callbacks
        await micAsr?.setEouCallback { [weak self] text in
            guard let self else { return }
            Task { await self.handleMicUtterance(text) }
        }

        await systemAsr?.setEouCallback { [weak self] text in
            guard let self else { return }
            Task { await self.handleSystemUtterance(text) }
        }
    }

    func endSession() async {
        // Flush remaining ASR audio
        if let micText = try? await micAsr?.finish(), !micText.isEmpty {
            let time = timeOffset(samples: micSamplesProcessed, sampleRate: micSampleRate)
            pendingEntries.append(TranscriptEntry(speaker: "You", text: micText, timestamp: time))
        }
        if let sysText = try? await systemAsr?.finish(), !sysText.isEmpty {
            let time = timeOffset(samples: systemSamplesProcessed, sampleRate: systemSampleRate)
            let speaker = currentSystemSpeaker(at: time)
            pendingEntries.append(TranscriptEntry(speaker: speaker, text: sysText, timestamp: time))
        }

        // Finalize diarizer
        _ = try? diarizer?.finalizeSession()

        // Flush all remaining entries
        flushAllEntries()

        transcriptHandle?.closeFile()
        transcriptHandle = nil
        sessionStart = nil
    }

    // MARK: - Audio Input

    func processMicAudio(_ samples: [Float], sampleRate: Double) async {
        guard let asr = micAsr else { return }
        if micSampleRate == 0 { micSampleRate = sampleRate }

        let buffer = makePCMBuffer(samples: samples, sampleRate: sampleRate)
        guard let buffer else { return }

        micSamplesProcessed += samples.count
        _ = try? await asr.process(audioBuffer: buffer)
    }

    func processSystemAudio(_ samples: [Float], sampleRate: Double) async {
        guard let asr = systemAsr else { return }
        if systemSampleRate == 0 { systemSampleRate = sampleRate }

        let buffer = makePCMBuffer(samples: samples, sampleRate: sampleRate)
        guard let buffer else { return }

        systemSamplesProcessed += samples.count

        // Feed ASR
        _ = try? await asr.process(audioBuffer: buffer)

        // Feed diarizer (it handles resampling internally)
        try? diarizer?.addAudio(samples, sourceSampleRate: sampleRate)
        _ = try? diarizer?.process()
    }

    // MARK: - EOU Handlers

    private func handleMicUtterance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let time = timeOffset(samples: micSamplesProcessed, sampleRate: micSampleRate)
        pendingEntries.append(TranscriptEntry(speaker: "You", text: trimmed, timestamp: time))
        flushOldEntries()
    }

    private func handleSystemUtterance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let time = timeOffset(samples: systemSamplesProcessed, sampleRate: systemSampleRate)
        let speaker = currentSystemSpeaker(at: time)
        pendingEntries.append(TranscriptEntry(speaker: speaker, text: trimmed, timestamp: time))
        flushOldEntries()
    }

    // MARK: - Diarization Speaker Lookup

    private func currentSystemSpeaker(at time: TimeInterval) -> String {
        guard let diarizer else { return labelForSpeaker(0) }

        let timeline = diarizer.timeline
        let speakers = timeline.speakers

        // Find the speaker whose segment covers this time
        let timeFloat = Float(time)
        for (_, speaker) in speakers {
            let allSegments = speaker.finalizedSegments + speaker.tentativeSegments
            for segment in allSegments {
                if segment.startTime <= timeFloat && timeFloat <= segment.endTime {
                    return labelForSpeaker(segment.speakerIndex)
                }
            }
        }

        // No match found — attribute to the most recently active speaker, or default
        if let lastSegment = speakers.values
            .flatMap({ $0.finalizedSegments + $0.tentativeSegments })
            .filter({ $0.endTime <= timeFloat })
            .max(by: { $0.endTime < $1.endTime }) {
            return labelForSpeaker(lastSegment.speakerIndex)
        }

        return labelForSpeaker(0)
    }

    private func labelForSpeaker(_ speakerIndex: Int) -> String {
        if let label = speakerLabels[speakerIndex] {
            return label
        }
        let label = "Person \(nextPersonNumber)"
        nextPersonNumber += 1
        speakerLabels[speakerIndex] = label
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

    private func timeOffset(samples: Int, sampleRate: Double) -> TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(samples) / sampleRate
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
