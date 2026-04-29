import AVFoundation
import CoreAudio
import Foundation
import ScreenCaptureKit
import SystemAudioTap
import Testing

// Each test isolates one step of the audio capture pipeline.
// Run with: swift test
// When a test crashes with EXC_BAD_ACCESS, the failing test name tells
// you exactly which step is the problem.

@Suite("System Audio Tap — C API", .serialized)
struct SystemAudioTapTests {
    @Test("IsSystemAudioTapAvailable returns without crashing")
    func availability() {
        let available = IsSystemAudioTapAvailable()
        print("IsSystemAudioTapAvailable: \(available)")
    }

    @Test("Step 1: CreateTapDescription (alloc + init + KVC)")
    func step1_createTapDescription() throws {
        guard IsSystemAudioTapAvailable() else { return }
        print("Calling CreateTapDescription...")
        let ptr = CreateTapDescription()
        print("CreateTapDescription returned: \(String(describing: ptr))")
        #expect(ptr != nil, "Tap description should be non-nil")
        // Note: leaks the object intentionally — just testing if it crashes
    }

    @Test("Step 2: AudioHardwareCreateProcessTap")
    func step2_createProcessTap() throws {
        guard IsSystemAudioTapAvailable() else { return }
        guard let descPtr = CreateTapDescription() else {
            Issue.record("CreateTapDescription returned nil")
            return
        }
        print("Calling CreateProcessTapFromDescription...")
        let tapID = CreateProcessTapFromDescription(descPtr)
        print("tapID: \(tapID)")
        #expect(tapID != 0, "tapID should be non-zero")

        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }

    @Test("Full CreateSystemAudioTap + Destroy roundtrip")
    func fullRoundtrip() throws {
        guard IsSystemAudioTapAvailable() else { return }
        let info = CreateSystemAudioTap()
        print("tapID: \(info.tapID), aggregateDeviceID: \(info.aggregateDeviceID)")
        #expect(info.tapID != 0, "tapID should be non-zero")
        #expect(info.aggregateDeviceID != 0, "aggregateDeviceID should be non-zero")
        DestroySystemAudioTap(info)
    }
}

@Suite("Microphone Engine")
struct MicrophoneEngineTests {
    @Test("Mic permission check")
    func micPermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        print("Mic authorization status: \(status.rawValue)")
        // 0=notDetermined, 1=restricted, 2=denied, 3=authorized

        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            print("Mic permission granted: \(granted)")
        }
    }

    @Test("Mic engine inputNode format")
    func micInputNodeFormat() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            print("⏭ Mic not authorized (status: \(status.rawValue)), skipping")
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        print("Mic format: \(format)")
        print("  sampleRate: \(format.sampleRate)")
        print("  channelCount: \(format.channelCount)")
        #expect(format.channelCount > 0, "Mic should have at least 1 channel")
        #expect(format.sampleRate > 0, "Mic should have a positive sample rate")
    }

    @Test("Mic engine install tap and start")
    func micInstallTapAndStart() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            print("⏭ Mic not authorized, skipping")
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            Issue.record("Invalid mic format")
            return
        }

        let tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hwFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

        var bufferCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { _, _ in
            bufferCount += 1
        }
        try engine.start()
        try await Task.sleep(for: .milliseconds(500))

        print("Mic engine received \(bufferCount) buffers")
        #expect(bufferCount > 0)

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

@Suite("ScreenCaptureKit Fallback")
struct SCKFallbackTests {
    @Test("SCShareableContent is accessible")
    func shareableContent() async throws {
        let content = try await SCShareableContent.current
        print("Displays: \(content.displays.count)")
        print("Windows: \(content.windows.count)")
        #expect(!content.displays.isEmpty, "Should have at least one display")
    }

    @Test("SCStream audio capture starts without crash")
    func sckAudioCapture() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            Issue.record("No display")
            return
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let delegate = TestSCStreamDelegate()
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        let outputQueue = DispatchQueue(label: "test.audio")
        try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: outputQueue)

        try await stream.startCapture()
        print("SCK stream started")

        try await Task.sleep(for: .milliseconds(500))

        print("SCK received \(delegate.bufferCount) audio buffers")

        try await stream.stopCapture()
        print("SCK stream stopped")
    }
}

// Helper for SCK tests
final class TestSCStreamDelegate: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    var bufferCount = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            bufferCount += 1
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("SCK stream error: \(error)")
    }
}

@Suite("Full Pipeline", .serialized)
struct FullPipelineTests {
    /// End-to-end check that the system-audio IOProc path actually delivers
    /// frames. Gated behind `CEREAL_AUDIO_INTEGRATION_TEST=1` because:
    ///   1. `swift test` runs outside the `.app` bundle, so TCC denies the
    ///      tap-aggregate creation — the test would always fail in CI/normal
    ///      local runs.
    ///   2. It requires real system audio playing during the run window to
    ///      observe non-zero buffers.
    /// To run this manually:
    ///   - Grant the test binary System Audio Recording permission, or run
    ///     it from a properly bundled `.app`.
    ///   - Start playing audio (any source) on the default output device.
    ///   - Run: `CEREAL_AUDIO_INTEGRATION_TEST=1 swift test --filter FullPipelineTests`
    ///
    /// This is the regression check that *should* have caught the AVAudioEngine
    /// vs. raw IOProc bug (the original assertion was just `fileSize > 44`,
    /// which a header-only WAV passes — false positive). The new assertion is
    /// on observed buffer count, not file size.
    @Test("System audio IOProc delivers buffers (integration)")
    func systemAudioIOProcDeliversBuffers() async throws {
        guard ProcessInfo.processInfo.environment["CEREAL_AUDIO_INTEGRATION_TEST"] == "1" else {
            print("⏭ Skipping — set CEREAL_AUDIO_INTEGRATION_TEST=1 to run")
            return
        }
        guard IsSystemAudioTapAvailable() else {
            print("⏭ Process tap not available")
            return
        }

        let info = CreateSystemAudioTap()
        guard info.tapID != 0, info.aggregateDeviceID != 0 else {
            Issue.record("Process tap creation failed (likely TCC denied — run from a bundled .app)")
            return
        }
        defer { DestroySystemAudioTap(info) }

        // Query the aggregate's input format — same path production uses.
        var streamFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let formatStatus = AudioObjectGetPropertyData(
            info.aggregateDeviceID, &formatAddr, 0, nil, &formatSize, &streamFormat)
        guard formatStatus == noErr, streamFormat.mSampleRate > 0 else {
            Issue.record("Failed to query aggregate input format: \(formatStatus)")
            return
        }
        print("Aggregate input format: sr=\(streamFormat.mSampleRate) ch=\(streamFormat.mChannelsPerFrame)")

        let counter = BufferCounter()
        let queue = DispatchQueue(label: "test.system-ioproc", qos: .userInteractive)
        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            info.aggregateDeviceID,
            queue
        ) { (_, inputData, _, _, _) in
            let abl = inputData.pointee
            guard abl.mNumberBuffers > 0 else { return }
            let firstBuffer = withUnsafePointer(to: inputData.pointee.mBuffers) { $0.pointee }
            let frames = Int(firstBuffer.mDataByteSize) / max(MemoryLayout<Float>.size, 1)
            counter.record(frames: frames)
        }
        guard createStatus == noErr, let procID else {
            Issue.record("AudioDeviceCreateIOProcIDWithBlock failed: \(createStatus)")
            return
        }
        defer { AudioDeviceDestroyIOProcID(info.aggregateDeviceID, procID) }

        let startStatus = AudioDeviceStart(info.aggregateDeviceID, procID)
        guard startStatus == noErr else {
            Issue.record("AudioDeviceStart failed: \(startStatus)")
            return
        }

        // Run for 1 s — needs real audio playing on the default output device
        // for buffers to carry non-zero samples, but the IOProc itself fires
        // regardless of whether anything is playing.
        try await Task.sleep(for: .seconds(1))

        AudioDeviceStop(info.aggregateDeviceID, procID)

        let (bufferCount, frameCount) = counter.snapshot()
        print("IOProc fired \(bufferCount) times, total frames: \(frameCount)")
        #expect(bufferCount > 0, "IOProc should have fired at least once in 1s")
        #expect(frameCount > 0, "IOProc should have delivered at least one frame")
    }
}

private final class BufferCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bufferCount = 0
    private var frameCount = 0

    func record(frames: Int) {
        lock.withLock {
            bufferCount += 1
            frameCount += frames
        }
    }

    func snapshot() -> (Int, Int) {
        lock.withLock { (bufferCount, frameCount) }
    }
}
