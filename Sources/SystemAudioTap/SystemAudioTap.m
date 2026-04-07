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

SystemAudioTapInfo CreateSystemAudioTap(void) {
    SystemAudioTapInfo info = {0, 0};

    if (!IsSystemAudioTapAvailable()) return info;

    id tap = CreateTapDescriptionObject();
    if (!tap) return info;

    // Configure the tap via KVC
    [tap setValue:@"CerealNotes-Audio-Tap" forKey:@"name"];
    [tap setValue:@0 forKey:@"muteBehavior"];
    [tap setValue:@YES forKey:@"private"];

    // Create the process tap
    AudioObjectID tapID = 0;
    OSStatus status = AudioHardwareCreateProcessTap(tap, &tapID);
    if (status != noErr || tapID == 0) return info;

    info.tapID = tapID;

    // Get the tap's UUID for the aggregate device tap list.
    // On macOS 26+, taps use kAudioAggregateDeviceTapListKey / kAudioSubTapUIDKey
    // instead of the old sub-device approach with kAudioDevicePropertyDeviceUID.
    NSUUID *tapUUID = [tap valueForKey:@"UUID"];
    if (!tapUUID) {
        AudioHardwareDestroyProcessTap(tapID);
        info.tapID = 0;
        return info;
    }

    NSString *tapUUIDString = [tapUUID UUIDString];

    // Create a private aggregate device that includes the tap
    NSDictionary *aggDesc = @{
        @(kAudioAggregateDeviceUIDKey): @"com.cerealnotes.system-audio",
        @(kAudioAggregateDeviceNameKey): @"CerealNotes System Audio",
        @(kAudioAggregateDeviceIsPrivateKey): @YES,
        @(kAudioAggregateDeviceIsStackedKey): @NO,
        @(kAudioAggregateDeviceTapListKey): @[
            @{@(kAudioSubTapUIDKey): tapUUIDString}
        ],
        @(kAudioAggregateDeviceTapAutoStartKey): @YES,
    };

    AudioDeviceID aggDeviceID = 0;
    status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggDesc, &aggDeviceID);
    if (status != noErr || aggDeviceID == 0) {
        AudioHardwareDestroyProcessTap(tapID);
        info.tapID = 0;
        return info;
    }

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

AudioDeviceID CreateAggregateDeviceFromTap(AudioObjectID tapID) {
    // Incomplete — requires the CATapDescription's UUID which isn't available
    // from just the tapID. Use CreateSystemAudioTap() for the full flow.
    (void)tapID;
    return 0;
}

void DestroySystemAudioTap(SystemAudioTapInfo info) {
    if (info.aggregateDeviceID != 0) {
        AudioHardwareDestroyAggregateDevice(info.aggregateDeviceID);
    }
    if (info.tapID != 0) {
        AudioHardwareDestroyProcessTap(info.tapID);
    }
}
