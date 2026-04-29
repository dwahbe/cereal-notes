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
        let uuid = desc.value(forKey: "UUID")
        print("UUID: \(String(describing: uuid))")

        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
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
