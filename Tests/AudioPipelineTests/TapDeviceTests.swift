import AVFoundation
import CoreAudio
import Foundation
import SystemAudioTap
import Testing

@Suite("Process Tap Device Investigation", .serialized)
struct TapDeviceTests {
    @Test("Check CATapDescription deviceUID after process tap creation")
    func tapDescriptionDeviceUID() {
        guard IsSystemAudioTapAvailable() else { return }
        guard let descPtr = CreateTapDescription() else { return }

        // Check deviceUID BEFORE creating process tap
        let desc = Unmanaged<AnyObject>.fromOpaque(descPtr).takeUnretainedValue()
        let uidBefore = desc.value(forKey: "deviceUID") as? String
        print("deviceUID BEFORE tap creation: \(uidBefore ?? "nil")")

        let tapID = CreateProcessTapFromDescription(descPtr)
        print("tapID: \(tapID)")

        // Check deviceUID AFTER creating process tap
        let uidAfter = desc.value(forKey: "deviceUID") as? String
        print("deviceUID AFTER tap creation: \(uidAfter ?? "nil")")

        // Check other properties
        let stream = desc.value(forKey: "stream") as? NSNumber
        print("stream: \(stream ?? 0)")
        let uuid = desc.value(forKey: "UUID") as? Any
        print("UUID: \(String(describing: uuid))")

        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }

    @Test("Try using tapID directly as audio device")
    func tapIDAsDevice() throws {
        guard IsSystemAudioTapAvailable() else { return }
        guard let descPtr = CreateTapDescription() else { return }
        let tapID = CreateProcessTapFromDescription(descPtr)
        guard tapID != 0 else { return }
        defer { AudioHardwareDestroyProcessTap(tapID) }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        guard let audioUnit = inputNode.audioUnit else {
            Issue.record("audioUnit nil")
            return
        }

        // Try using the tapID directly as the device
        var deviceID = tapID
        let err = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        print("Using tapID (\(tapID)) as device: status=\(err)")

        if err == noErr {
            let format = inputNode.outputFormat(forBus: 0)
            print("Format: rate=\(format.sampleRate) ch=\(format.channelCount)")

            if format.channelCount > 0 && format.sampleRate > 0 {
                let tapFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: format.sampleRate,
                    channels: 1,
                    interleaved: false
                )!
                var bufferCount = 0
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { _, _ in
                    bufferCount += 1
                }
                try engine.start()
                Thread.sleep(forTimeInterval: 0.5)
                print("Received \(bufferCount) buffers via tapID-as-device")
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }
    }

    @Test("Query available properties on tap AudioObject")
    func queryTapProperties() {
        guard IsSystemAudioTapAvailable() else { return }
        guard let descPtr = CreateTapDescription() else { return }
        let tapID = CreateProcessTapFromDescription(descPtr)
        guard tapID != 0 else { return }
        defer { AudioHardwareDestroyProcessTap(tapID) }

        // Try various properties
        let properties: [(String, AudioObjectPropertySelector)] = [
            ("kAudioObjectPropertyName", kAudioObjectPropertyName),
            ("kAudioObjectPropertyClass", kAudioObjectPropertyClass),
            ("kAudioDevicePropertyDeviceUID", kAudioDevicePropertyDeviceUID),
            ("kAudioDevicePropertyStreams", kAudioDevicePropertyStreams),
            ("kAudioDevicePropertyNominalSampleRate", kAudioDevicePropertyNominalSampleRate),
        ]

        for (name, selector) in properties {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let has = AudioObjectHasProperty(tapID, &addr)
            print("\(name): hasProperty=\(has)")

            if has {
                var size: UInt32 = 0
                let sizeStatus = AudioObjectGetPropertyDataSize(tapID, &addr, 0, nil, &size)
                print("  dataSize=\(size) status=\(sizeStatus)")
            }
        }
    }
}
