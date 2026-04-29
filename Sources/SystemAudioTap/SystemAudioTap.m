#import "include/SystemAudioTap.h"
#import <CoreAudio/CoreAudio.h>
#import <objc/runtime.h>

// Private CoreAudio functions (weak-linked so we can check availability at runtime)
extern OSStatus AudioHardwareCreateProcessTap(id tapDescription, AudioObjectID *tapID)
    __attribute__((weak_import));
extern OSStatus AudioHardwareDestroyProcessTap(AudioObjectID tapID)
    __attribute__((weak_import));

bool IsSystemAudioTapAvailable(void) {
    if (!AudioHardwareCreateProcessTap) return false;
    if (!AudioHardwareDestroyProcessTap) return false;

    Class CATapDescription = NSClassFromString(@"CATapDescription");
    if (!CATapDescription) return false;

    SEL initSel = NSSelectorFromString(@"initMonoGlobalTapButExcludeProcesses:");
    if (![CATapDescription instancesRespondToSelector:initSel]) return false;

    return true;
}

/// Create a CATapDescription safely, avoiding the ARC + performSelector: ownership bug.
/// When performSelector: calls an init method, ARC doesn't know init consumed the
/// alloc'd receiver. If init returns a *different* pointer (class clusters), ARC
/// double-frees the original → EXC_BAD_ACCESS.
/// Fix: use raw IMP with manual bridging to handle ownership transfer explicitly.
static id CreateTapDescriptionObject(void) {
    Class CATapDescription = NSClassFromString(@"CATapDescription");
    SEL initSel = NSSelectorFromString(@"initMonoGlobalTapButExcludeProcesses:");
    IMP initIMP = [CATapDescription instanceMethodForSelector:initSel];

    // Move alloc result out of ARC ownership into manual refcounting
    void *allocated = (__bridge_retained void *)[CATapDescription alloc];

    // Call init — consumes allocated's +1, returns +1
    void *result = ((void *(*)(void *, SEL, id))initIMP)(allocated, initSel, @[]);

    // Transfer the +1 return back to ARC
    return (__bridge_transfer id)result;
}

// FourCC OSStatus → printable string for logging (e.g. 'priv' / '!pri')
static NSString *FourCCString(OSStatus status) {
    char chars[5];
    chars[0] = (status >> 24) & 0xff;
    chars[1] = (status >> 16) & 0xff;
    chars[2] = (status >> 8)  & 0xff;
    chars[3] = (status >> 0)  & 0xff;
    chars[4] = 0;
    BOOL printable = YES;
    for (int i = 0; i < 4; i++) {
        if (chars[i] < 0x20 || chars[i] > 0x7e) { printable = NO; break; }
    }
    if (printable) return [NSString stringWithFormat:@"'%s' (%d)", chars, (int)status];
    return [NSString stringWithFormat:@"%d", (int)status];
}

SystemAudioTapInfo CreateSystemAudioTap(void) {
    SystemAudioTapInfo info = {0, 0};

    if (!IsSystemAudioTapAvailable()) {
        NSLog(@"[CerealNotes/Tap] IsSystemAudioTapAvailable returned false");
        return info;
    }

    id tap = CreateTapDescriptionObject();
    if (!tap) {
        NSLog(@"[CerealNotes/Tap] CreateTapDescriptionObject returned nil");
        return info;
    }

    // Configure the tap via KVC
    [tap setValue:@"CerealNotes-Audio-Tap" forKey:@"name"];
    [tap setValue:@0 forKey:@"muteBehavior"];
    [tap setValue:@YES forKey:@"private"];

    // Create the process tap
    AudioObjectID tapID = 0;
    OSStatus status = AudioHardwareCreateProcessTap(tap, &tapID);
    if (status != noErr || tapID == 0) {
        NSLog(@"[CerealNotes/Tap] AudioHardwareCreateProcessTap failed status=%@ tapID=%u",
              FourCCString(status), tapID);
        return info;
    }
    NSLog(@"[CerealNotes/Tap] AudioHardwareCreateProcessTap ok tapID=%u", tapID);

    info.tapID = tapID;

    // Get the tap's UUID for the aggregate device tap list.
    // On macOS 26+, taps use kAudioAggregateDeviceTapListKey / kAudioSubTapUIDKey
    // instead of the old sub-device approach with kAudioDevicePropertyDeviceUID.
    NSUUID *tapUUID = [tap valueForKey:@"UUID"];
    if (!tapUUID) {
        NSLog(@"[CerealNotes/Tap] tap UUID was nil — destroying tap");
        AudioHardwareDestroyProcessTap(tapID);
        info.tapID = 0;
        return info;
    }

    NSString *tapUUIDString = [tapUUID UUIDString];

    // Look up the default output device + its UID. The aggregate device needs
    // a real clock source; an aggregate that contains only a tap has no clock
    // and never fires its IO proc → tap delivers zero buffers. The pattern
    // (matches Apple's sample + AudioCap): include the current default output
    // as the main sub-device, and let the tap capture what's sent to it.
    AudioObjectID defaultOutputDevice = kAudioObjectUnknown;
    UInt32 sizeOfDeviceID = sizeof(defaultOutputDevice);
    AudioObjectPropertyAddress defaultOutputAddr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    OSStatus defaultStatus = AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &defaultOutputAddr, 0, NULL,
        &sizeOfDeviceID, &defaultOutputDevice);
    if (defaultStatus != noErr || defaultOutputDevice == kAudioObjectUnknown) {
        NSLog(@"[CerealNotes/Tap] could not resolve default output device status=%@ id=%u",
              FourCCString(defaultStatus), defaultOutputDevice);
        AudioHardwareDestroyProcessTap(tapID);
        info.tapID = 0;
        return info;
    }

    CFStringRef outputUIDRef = NULL;
    UInt32 sizeOfUIDRef = sizeof(outputUIDRef);
    AudioObjectPropertyAddress uidAddr = {
        kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    OSStatus uidStatus = AudioObjectGetPropertyData(
        defaultOutputDevice, &uidAddr, 0, NULL,
        &sizeOfUIDRef, &outputUIDRef);
    if (uidStatus != noErr || outputUIDRef == NULL) {
        NSLog(@"[CerealNotes/Tap] could not resolve default output UID status=%@",
              FourCCString(uidStatus));
        AudioHardwareDestroyProcessTap(tapID);
        info.tapID = 0;
        return info;
    }
    NSString *outputUID = (__bridge_transfer NSString *)outputUIDRef;
    NSLog(@"[CerealNotes/Tap] default output device id=%u uid=%@", defaultOutputDevice, outputUID);

    // Create a private aggregate device that contains the default output as
    // the main sub-device + clock source, with the process tap as a sub-tap.
    NSDictionary *aggDesc = @{
        @(kAudioAggregateDeviceUIDKey): @"com.cerealnotes.system-audio",
        @(kAudioAggregateDeviceNameKey): @"CerealNotes System Audio",
        @(kAudioAggregateDeviceIsPrivateKey): @YES,
        @(kAudioAggregateDeviceIsStackedKey): @NO,
        @(kAudioAggregateDeviceMainSubDeviceKey): outputUID,
        @(kAudioAggregateDeviceSubDeviceListKey): @[
            @{ @(kAudioSubDeviceUIDKey): outputUID }
        ],
        @(kAudioAggregateDeviceTapListKey): @[
            @{
                @(kAudioSubTapUIDKey): tapUUIDString,
                @(kAudioSubTapDriftCompensationKey): @YES,
            }
        ],
        @(kAudioAggregateDeviceTapAutoStartKey): @YES,
    };

    AudioDeviceID aggDeviceID = 0;
    status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggDesc, &aggDeviceID);
    if (status != noErr || aggDeviceID == 0) {
        NSLog(@"[CerealNotes/Tap] AudioHardwareCreateAggregateDevice failed status=%@ aggDeviceID=%u",
              FourCCString(status), aggDeviceID);
        AudioHardwareDestroyProcessTap(tapID);
        info.tapID = 0;
        return info;
    }
    NSLog(@"[CerealNotes/Tap] aggregate device created aggDeviceID=%u tapUUID=%@ mainSub=%@",
          aggDeviceID, tapUUIDString, outputUID);

    info.aggregateDeviceID = aggDeviceID;
    return info;
}

// MARK: - Diagnostic functions

void *_Nullable CreateTapDescription(void) {
    if (!IsSystemAudioTapAvailable()) return NULL;
    id tap = CreateTapDescriptionObject();
    if (!tap) return NULL;

    [tap setValue:@"CerealNotes-Audio-Tap" forKey:@"name"];
    [tap setValue:@0 forKey:@"muteBehavior"];
    [tap setValue:@YES forKey:@"private"];

    return (__bridge_retained void *)tap;
}

AudioObjectID CreateProcessTapFromDescription(void *_Nonnull tapDescription) {
    id tap = (__bridge id)tapDescription;
    AudioObjectID tapID = 0;
    OSStatus status = AudioHardwareCreateProcessTap(tap, &tapID);
    if (status != noErr) return 0;
    return tapID;
}

void DestroySystemAudioTap(SystemAudioTapInfo info) {
    if (info.aggregateDeviceID != 0) {
        AudioHardwareDestroyAggregateDevice(info.aggregateDeviceID);
    }
    if (info.tapID != 0) {
        AudioHardwareDestroyProcessTap(info.tapID);
    }
}
