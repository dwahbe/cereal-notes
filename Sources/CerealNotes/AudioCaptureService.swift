import AVFoundation
import CoreAudio
import ScreenCaptureKit
import SystemAudioTap

/// Which capture path this session used — reported in session diagnostics.
enum AudioCapturePath: String, Codable {
    case processTap
    case screenCaptureKit
}

/// Per-stream statistics captured during the session.
struct AudioStreamStats: Codable {
    var bufferCount: Int = 0
    var sampleCount: Int = 0
    var sampleRate: Double = 0
}

struct AudioCaptureStats: Codable {
    var path: AudioCapturePath?
    var system = AudioStreamStats()
    var mic = AudioStreamStats()
}

final class AudioCaptureService: NSObject, @unchecked Sendable {
    private var tapInfo = SystemAudioTapInfo(tapID: 0, aggregateDeviceID: 0)
    private var systemEngine: AVAudioEngine?
    private var micEngine: AVAudioEngine?
    private var systemAudioFile: AVAudioFile?
    private var micAudioFile: AVAudioFile?
    private let lock = NSLock()

    // Fallback for when process tap is unavailable
    private var stream: SCStream?

    private var onError: (@Sendable (Error) -> Void)?

    /// Called with ([Float] samples, Double sampleRate) for each system audio buffer.
    var onSystemAudioBuffer: (@Sendable ([Float], Double) -> Void)?
    /// Called with ([Float] samples, Double sampleRate) for each mic audio buffer.
    var onMicAudioBuffer: (@Sendable ([Float], Double) -> Void)?

    private static let sampleRate: Double = 48000
    private static let channelCount: AVAudioChannelCount = 1

    // Capture diagnostics — read after stopCapture() to write session.json.
    private var stats = AudioCaptureStats()

    /// Snapshot of stats since the last startCapture() call.
    func currentStats() -> AudioCaptureStats {
        lock.withLock { stats }
    }

    // MARK: - Public API

    func startCapture(sessionDir: URL, onError: @escaping @Sendable (Error) -> Void) async throws {
        self.onError = onError
        lock.withLock { stats = AudioCaptureStats() }

        // Request mic permission upfront — accessing AVAudioEngine.inputNode
        // without permission can crash on macOS 15+.
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)

        if IsSystemAudioTapAvailable() {
            do {
                try startWithProcessTap(sessionDir: sessionDir, micGranted: micGranted)
                lock.withLock { stats.path = .processTap }
                return
            } catch {
                // Process tap failed — clean up partial state, fall through to SCK
                cleanupEngines()
            }
        }
        try await startWithScreenCaptureKit(sessionDir: sessionDir, micGranted: micGranted)
        lock.withLock { stats.path = .screenCaptureKit }
    }

    func stopCapture() async {
        cleanupEngines()

        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }

        lock.withLock {
            systemAudioFile = nil
            micAudioFile = nil
        }
        onError = nil
        onSystemAudioBuffer = nil
        onMicAudioBuffer = nil
    }

    // MARK: - Process Tap (Primary — triggers "System Audio Recording Only")

    private func startWithProcessTap(sessionDir: URL, micGranted: Bool) throws {
        let info = CreateSystemAudioTap()
        guard info.tapID != 0, info.aggregateDeviceID != 0 else {
            throw AudioCaptureError.processTapFailed
        }
        tapInfo = info

        // --- System Audio Engine ---
        let sysEngine = AVAudioEngine()
        let sysInputNode = sysEngine.inputNode

        guard let audioUnit = sysInputNode.audioUnit else {
            throw AudioCaptureError.audioUnitConfigFailed
        }

        var deviceID = info.aggregateDeviceID
        let err = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard err == noErr else {
            throw AudioCaptureError.audioUnitConfigFailed
        }

        let sysHwFormat = sysInputNode.outputFormat(forBus: 0)
        guard sysHwFormat.channelCount > 0, sysHwFormat.sampleRate > 0 else {
            throw AudioCaptureError.audioUnitConfigFailed
        }

        // Use the hardware's sample rate — installTap on inputNode requires it.
        // Only change channel count (to mono) and sample format (to float32).
        let sysTapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sysHwFormat.sampleRate,
            channels: Self.channelCount,
            interleaved: false
        )!

        let systemFile = try AVAudioFile(
            forWriting: sessionDir.appendingPathComponent("system.wav"),
            settings: sysTapFormat.settings
        )
        lock.withLock { systemAudioFile = systemFile }

        sysInputNode.installTap(onBus: 0, bufferSize: 4096, format: sysTapFormat) { [weak self] buffer, _ in
            self?.writeBuffer(buffer, for: \.systemAudioFile)
            self?.recordStats(frames: Int(buffer.frameLength), rate: sysTapFormat.sampleRate, side: .system)
            if let callback = self?.onSystemAudioBuffer,
               let data = buffer.floatChannelData?[0] {
                let samples = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
                callback(samples, sysTapFormat.sampleRate)
            }
        }
        try sysEngine.start()
        systemEngine = sysEngine

        // --- Microphone Engine (optional — skip if permission denied) ---
        guard micGranted else { return }

        let micEng = AVAudioEngine()
        let micInputNode = micEng.inputNode
        let micHwFormat = micInputNode.outputFormat(forBus: 0)
        guard micHwFormat.channelCount > 0, micHwFormat.sampleRate > 0 else {
            return // No mic available — continue with system audio only
        }

        let micTapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: micHwFormat.sampleRate,
            channels: Self.channelCount,
            interleaved: false
        )!

        let micFile = try AVAudioFile(
            forWriting: sessionDir.appendingPathComponent("mic.wav"),
            settings: micTapFormat.settings
        )
        lock.withLock { micAudioFile = micFile }

        micInputNode.installTap(onBus: 0, bufferSize: 4096, format: micTapFormat) { [weak self] buffer, _ in
            self?.writeBuffer(buffer, for: \.micAudioFile)
            self?.recordStats(frames: Int(buffer.frameLength), rate: micTapFormat.sampleRate, side: .mic)
            if let callback = self?.onMicAudioBuffer,
               let data = buffer.floatChannelData?[0] {
                let samples = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
                callback(samples, micTapFormat.sampleRate)
            }
        }
        try micEng.start()
        micEngine = micEng
    }

    // MARK: - ScreenCaptureKit Fallback

    private func startWithScreenCaptureKit(sessionDir: URL, micGranted: Bool) async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayFound
        }

        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channelCount,
            interleaved: false
        )!

        let systemFile = try AVAudioFile(
            forWriting: sessionDir.appendingPathComponent("system.wav"),
            settings: outputFormat.settings
        )
        let micFile = try AVAudioFile(
            forWriting: sessionDir.appendingPathComponent("mic.wav"),
            settings: outputFormat.settings
        )
        lock.withLock {
            systemAudioFile = systemFile
            micAudioFile = micFile
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = micGranted
        config.sampleRate = Int(Self.sampleRate)
        config.channelCount = Int(Self.channelCount)
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let outputQueue = DispatchQueue(label: "com.cerealnotes.audio-capture")
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        if micGranted {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: outputQueue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    // MARK: - Cleanup

    private func cleanupEngines() {
        systemEngine?.inputNode.removeTap(onBus: 0)
        systemEngine?.stop()
        systemEngine = nil

        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil

        if tapInfo.tapID != 0 {
            DestroySystemAudioTap(tapInfo)
            tapInfo = SystemAudioTapInfo(tapID: 0, aggregateDeviceID: 0)
        }
    }

    // MARK: - Audio Writing

    private func writeBuffer(_ buffer: AVAudioPCMBuffer, for keyPath: KeyPath<AudioCaptureService, AVAudioFile?>) {
        lock.withLock {
            guard let file = self[keyPath: keyPath] else { return }
            do {
                try file.write(from: buffer)
            } catch {
                onError?(error)
            }
        }
    }

    private enum StreamSide { case system, mic }

    private func recordStats(frames: Int, rate: Double, side: StreamSide) {
        lock.withLock {
            switch side {
            case .system:
                stats.system.bufferCount += 1
                stats.system.sampleCount += frames
                stats.system.sampleRate = rate
            case .mic:
                stats.mic.bufferCount += 1
                stats.mic.sampleCount += frames
                stats.mic.sampleRate = rate
            }
        }
    }

    /// Convert CMSampleBuffer to AVAudioPCMBuffer and write (SCK fallback only)
    private func writeSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        to keyPath: KeyPath<AudioCaptureService, AVAudioFile?>,
        callback: ((@Sendable ([Float], Double) -> Void))? = nil
    ) {
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: asbd),
              let blockBuffer = sampleBuffer.dataBuffer else {
            return
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return
        }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        var dataLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &dataLength, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let dataPointer else { return }

        // Ensure we have float channel data (SCK should always deliver float32)
        guard let destPtr = pcmBuffer.floatChannelData?[0] else { return }

        let bytesToCopy = min(dataLength, Int(pcmBuffer.frameLength) * Int(format.streamDescription.pointee.mBytesPerFrame))
        memcpy(destPtr, dataPointer, bytesToCopy)

        writeBuffer(pcmBuffer, for: keyPath)

        if let callback {
            let samples = Array(UnsafeBufferPointer(start: destPtr, count: Int(pcmBuffer.frameLength)))
            callback(samples, format.sampleRate)
        }
    }

}

// MARK: - SCStreamOutput (fallback)

extension AudioCaptureService: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let rate = CMAudioFormatDescriptionGetStreamBasicDescription(sampleBuffer.formatDescription!)?.pointee.mSampleRate ?? 0
        switch type {
        case .audio:
            writeSampleBuffer(sampleBuffer, to: \.systemAudioFile, callback: onSystemAudioBuffer)
            recordStats(frames: frames, rate: rate, side: .system)
        case .microphone:
            writeSampleBuffer(sampleBuffer, to: \.micAudioFile, callback: onMicAudioBuffer)
            recordStats(frames: frames, rate: rate, side: .mic)
        case .screen:
            break
        @unknown default:
            break
        }
    }
}

// MARK: - SCStreamDelegate (fallback)

extension AudioCaptureService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}

// MARK: - Errors

enum AudioCaptureError: LocalizedError {
    case noDisplayFound
    case processTapFailed
    case audioUnitConfigFailed
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return "No display found for audio capture."
        case .processTapFailed:
            return "Failed to create system audio tap. Check System Audio Recording permission in System Settings."
        case .audioUnitConfigFailed:
            return "Failed to configure audio input device."
        case .microphoneUnavailable:
            return "Microphone is unavailable. Check microphone permission in System Settings."
        }
    }
}
