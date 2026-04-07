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

    @Test("Step 3: Create aggregate device from tap")
    func step3_createAggregateDevice() throws {
        guard IsSystemAudioTapAvailable() else { return }
        guard let descPtr = CreateTapDescription() else { return }
        let tapID = CreateProcessTapFromDescription(descPtr)
        guard tapID != 0 else {
            Issue.record("Process tap creation failed")
            return
        }
        defer { AudioHardwareDestroyProcessTap(tapID) }

        print("Calling CreateAggregateDeviceFromTap...")
        let aggID = CreateAggregateDeviceFromTap(tapID)
        print("aggregateDeviceID: \(aggID)")
        #expect(aggID != 0, "Aggregate device ID should be non-zero")

        if aggID != 0 {
            AudioHardwareDestroyAggregateDevice(aggID)
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

@Suite("Aggregate Device — AVAudioEngine Setup", .serialized)
struct AggregateDeviceTests {
    @Test("AVAudioEngine inputNode has a valid audioUnit")
    func engineInputNodeAudioUnit() {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        #expect(inputNode.audioUnit != nil, "audioUnit should not be nil")
    }

    @Test("Can assign aggregate device to engine input")
    func assignAggregateDevice() throws {
        guard IsSystemAudioTapAvailable() else {
            print("⏭ Skipping — process tap not available")
            return
        }

        let info = CreateSystemAudioTap()
        defer { DestroySystemAudioTap(info) }
        #expect(info.aggregateDeviceID != 0)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        guard let audioUnit = inputNode.audioUnit else {
            Issue.record("audioUnit is nil")
            return
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
        #expect(err == noErr, "AudioUnitSetProperty should succeed, got \(err)")
    }

    @Test("Aggregate device reports valid format after assignment")
    func aggregateDeviceFormat() throws {
        guard IsSystemAudioTapAvailable() else { return }

        let info = CreateSystemAudioTap()
        defer { DestroySystemAudioTap(info) }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        guard let audioUnit = inputNode.audioUnit else {
            Issue.record("audioUnit is nil")
            return
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
            Issue.record("AudioUnitSetProperty failed: \(err)")
            return
        }

        let format = inputNode.outputFormat(forBus: 0)
        print("Aggregate device format: \(format)")
        print("  sampleRate: \(format.sampleRate)")
        print("  channelCount: \(format.channelCount)")
        print("  commonFormat: \(format.commonFormat.rawValue)")
        #expect(format.channelCount > 0, "Should have at least 1 channel")
        #expect(format.sampleRate > 0, "Should have a positive sample rate")
    }
}

@Suite("System Audio Engine — Tap + Start", .serialized)
struct SystemAudioEngineTests {
    @Test("Install tap with hardware-matching format and start engine")
    func installTapAndStart() throws {
        guard IsSystemAudioTapAvailable() else { return }

        let info = CreateSystemAudioTap()
        var engine: AVAudioEngine? = AVAudioEngine()
        defer {
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            DestroySystemAudioTap(info)
        }

        let inputNode = engine!.inputNode
        guard let audioUnit = inputNode.audioUnit else {
            Issue.record("audioUnit is nil")
            return
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
            Issue.record("AudioUnitSetProperty failed")
            return
        }

        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            Issue.record("Invalid hardware format: \(hwFormat)")
            return
        }

        // Key: use hardware sample rate (required by inputNode), mono, float32
        let tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hwFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

        print("Using tap format: \(tapFormat)")

        var bufferCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, time in
            bufferCount += 1
        }

        try engine!.start()
        print("Engine started successfully")

        // Let it run briefly to confirm callbacks fire without crashing
        Thread.sleep(forTimeInterval: 0.5)

        print("Received \(bufferCount) audio buffers")
        #expect(bufferCount > 0, "Should have received at least one audio buffer")

        engine!.inputNode.removeTap(onBus: 0)
        engine!.stop()
        engine = nil
    }

    @Test("Install tap with MISMATCHED sample rate (expect failure, not crash)")
    func installTapMismatchedSampleRate() throws {
        guard IsSystemAudioTapAvailable() else { return }

        let info = CreateSystemAudioTap()
        defer { DestroySystemAudioTap(info) }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        guard let audioUnit = inputNode.audioUnit else { return }

        var deviceID = info.aggregateDeviceID
        let err = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard err == noErr else { return }

        let hwFormat = inputNode.outputFormat(forBus: 0)
        // Intentionally use a DIFFERENT sample rate than hardware
        let wrongRate: Double = hwFormat.sampleRate == 48000 ? 44100 : 48000
        let badFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: wrongRate,
            channels: 1,
            interleaved: false
        )!

        print("Hardware rate: \(hwFormat.sampleRate), trying: \(wrongRate)")

        // This may crash (EXC_BAD_ACCESS) or throw — the test documents which.
        // If this test crashes, that confirms sample rate mismatch is the root cause.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: badFormat) { _, _ in }
        do {
            try engine.start()
            print("Engine started with mismatched rate (unexpected success)")
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        } catch {
            print("Engine start threw with mismatched rate: \(error)")
        }
    }

    @Test("Install tap with nil format (native format)")
    func installTapNilFormat() throws {
        guard IsSystemAudioTapAvailable() else { return }

        let info = CreateSystemAudioTap()
        defer { DestroySystemAudioTap(info) }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        guard let audioUnit = inputNode.audioUnit else { return }

        var deviceID = info.aggregateDeviceID
        _ = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        // nil format = use node's native format. Safest option.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            // Print format of first buffer to see what the device actually delivers
        }
        try engine.start()
        Thread.sleep(forTimeInterval: 0.3)

        print("Engine with nil format started OK")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
    @Test("System audio + mic capture writes valid WAV files")
    func fullCapture() async throws {
        guard IsSystemAudioTapAvailable() else {
            print("⏭ Process tap not available")
            return
        }

        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        print("Mic granted: \(micGranted)")

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cereal-notes-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let info = CreateSystemAudioTap()
        guard info.tapID != 0, info.aggregateDeviceID != 0 else {
            Issue.record("Process tap creation failed")
            return
        }
        defer { DestroySystemAudioTap(info) }

        // System engine
        let sysEngine = AVAudioEngine()
        let sysInputNode = sysEngine.inputNode
        guard let audioUnit = sysInputNode.audioUnit else {
            Issue.record("audioUnit nil")
            return
        }

        var deviceID = info.aggregateDeviceID
        let err = AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard err == noErr else {
            Issue.record("AudioUnitSetProperty failed: \(err)")
            return
        }

        let hwFormat = sysInputNode.outputFormat(forBus: 0)
        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            Issue.record("Bad hw format: \(hwFormat)")
            return
        }

        let tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hwFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let sysFile = try AVAudioFile(
            forWriting: tmpDir.appendingPathComponent("system.wav"),
            settings: tapFormat.settings
        )

        let lock = NSLock()
        sysInputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
            lock.withLock {
                try? sysFile.write(from: buffer)
            }
        }

        try sysEngine.start()
        print("System engine started")

        // Record for 1 second
        try await Task.sleep(for: .seconds(1))

        sysEngine.inputNode.removeTap(onBus: 0)
        sysEngine.stop()

        let fileSize = try FileManager.default.attributesOfItem(
            atPath: tmpDir.appendingPathComponent("system.wav").path
        )[.size] as? Int ?? 0
        print("system.wav size: \(fileSize) bytes")
        #expect(fileSize > 44, "WAV file should have data beyond the header")
    }
}
