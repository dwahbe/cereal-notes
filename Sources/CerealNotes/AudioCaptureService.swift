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
    private var systemIOProcID: AudioDeviceIOProcID?
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
            NSLog("[CerealNotes/Capture] processTap path: tap creation returned zero IDs — falling back")
            throw AudioCaptureError.processTapFailed
        }
        tapInfo = info
        NSLog("[CerealNotes/Capture] processTap path: tap=\(info.tapID) agg=\(info.aggregateDeviceID)")

        // --- System Audio via raw AudioDeviceIOProc ---
        // AVAudioEngine + installTap doesn't reliably surface sub-tap audio
        // from a tap-aggregate device on macOS 14+. Use a raw IOProc so the
        // audio HAL delivers buffers directly.
        try startSystemAudioIOProc(sessionDir: sessionDir, aggDeviceID: info.aggregateDeviceID)

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

    // MARK: - System Audio IOProc (raw HAL — bypasses AVAudioEngine)

    private func startSystemAudioIOProc(sessionDir: URL, aggDeviceID: AudioDeviceID) throws {
        // Query the aggregate's input stream format so we know the rate the
        // tap is delivering at. The format is determined by the tap + clock
        // sub-device.
        var streamFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let formatStatus = AudioObjectGetPropertyData(
            aggDeviceID, &formatAddr, 0, nil, &formatSize, &streamFormat)
        guard formatStatus == noErr, streamFormat.mSampleRate > 0, streamFormat.mChannelsPerFrame > 0 else {
            NSLog("[CerealNotes/Capture] failed to query agg input format status=\(formatStatus) sr=\(streamFormat.mSampleRate) ch=\(streamFormat.mChannelsPerFrame)")
            throw AudioCaptureError.audioUnitConfigFailed
        }
        let sourceSampleRate = streamFormat.mSampleRate
        let sourceChannels = AVAudioChannelCount(streamFormat.mChannelsPerFrame)
        let sourceIsInterleaved = (streamFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        NSLog("[CerealNotes/Capture] agg input format sr=\(sourceSampleRate) ch=\(sourceChannels) interleaved=\(sourceIsInterleaved) flags=\(streamFormat.mFormatFlags)")

        // Write file format: mono float32 at the source rate.
        let writeFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        )!

        let systemFile = try AVAudioFile(
            forWriting: sessionDir.appendingPathComponent("system.wav"),
            settings: writeFormat.settings
        )
        lock.withLock { systemAudioFile = systemFile }

        // Per-cycle conversion buffer — sized for max expected frames.
        // The HAL block fires with whatever the device's IO block size is
        // (commonly 512–4096 frames).
        let pcmCapacity: AVAudioFrameCount = 8192

        let ioQueue = DispatchQueue(label: "com.cerealnotes.system-ioproc", qos: .userInteractive)

        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggDeviceID,
            ioQueue
        ) { [weak self] (_, inputData, _, _, _) in
            guard let self else { return }
            let abl = inputData.pointee
            guard abl.mNumberBuffers > 0 else { return }
            let firstBuffer = withUnsafePointer(to: inputData.pointee.mBuffers) { $0.pointee }
            guard let mData = firstBuffer.mData else { return }
            let channels = max(Int(firstBuffer.mNumberChannels), 1)
            let bytesPerFrame = MemoryLayout<Float>.size * (sourceIsInterleaved ? channels : 1)
            let totalBytes = Int(firstBuffer.mDataByteSize)
            let frameCount = totalBytes / max(bytesPerFrame, 1)
            guard frameCount > 0 else { return }

            guard let pcm = AVAudioPCMBuffer(pcmFormat: writeFormat, frameCapacity: pcmCapacity) else { return }
            let writeFrames = min(frameCount, Int(pcmCapacity))
            pcm.frameLength = AVAudioFrameCount(writeFrames)
            guard let dest = pcm.floatChannelData?[0] else { return }

            let src = mData.bindMemory(to: Float.self, capacity: frameCount * channels)
            if channels == 1 {
                dest.update(from: src, count: writeFrames)
            } else if sourceIsInterleaved {
                // Mix interleaved multichannel down to mono by averaging.
                for f in 0..<writeFrames {
                    var sum: Float = 0
                    for c in 0..<channels {
                        sum += src[f * channels + c]
                    }
                    dest[f] = sum / Float(channels)
                }
            } else {
                // Non-interleaved: each channel is in its own AudioBuffer; use buffer 0
                // as the mono source. (Common for taps; we got here because numBuffers
                // > 1 wasn't iterated. Treat as mono passthrough.)
                dest.update(from: src, count: writeFrames)
            }

            let isFirst = lock.withLock { stats.system.bufferCount == 0 }
            if isFirst {
                NSLog("[CerealNotes/Capture] system IOProc FIRST buffer frames=\(writeFrames) sr=\(sourceSampleRate)")
            }
            writeBuffer(pcm, for: \.systemAudioFile)
            recordStats(frames: writeFrames, rate: sourceSampleRate, side: .system)
            if let callback = onSystemAudioBuffer {
                let samples = Array(UnsafeBufferPointer(start: dest, count: writeFrames))
                callback(samples, sourceSampleRate)
            }
        }
        guard createStatus == noErr, let procID else {
            NSLog("[CerealNotes/Capture] AudioDeviceCreateIOProcIDWithBlock failed status=\(createStatus)")
            throw AudioCaptureError.audioUnitConfigFailed
        }
        systemIOProcID = procID

        let startStatus = AudioDeviceStart(aggDeviceID, procID)
        guard startStatus == noErr else {
            NSLog("[CerealNotes/Capture] AudioDeviceStart failed status=\(startStatus)")
            AudioDeviceDestroyIOProcID(aggDeviceID, procID)
            systemIOProcID = nil
            throw AudioCaptureError.audioUnitConfigFailed
        }
        NSLog("[CerealNotes/Capture] system IOProc started on aggDevice=\(aggDeviceID)")
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
        if let procID = systemIOProcID, tapInfo.aggregateDeviceID != 0 {
            AudioDeviceStop(tapInfo.aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(tapInfo.aggregateDeviceID, procID)
        }
        systemIOProcID = nil

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
