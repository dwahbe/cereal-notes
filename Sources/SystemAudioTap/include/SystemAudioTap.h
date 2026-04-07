#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>

typedef struct {
    AudioObjectID tapID;
    AudioDeviceID aggregateDeviceID;
} SystemAudioTapInfo;

/// Check if the CoreAudio process tap API is available.
bool IsSystemAudioTapAvailable(void);

/// Create a global system audio process tap and aggregate device.
/// Triggers the "System Audio Recording Only" TCC permission.
/// Returns info with both IDs, or {0, 0} on failure.
SystemAudioTapInfo CreateSystemAudioTap(void);

/// Destroy the process tap and aggregate device.
void DestroySystemAudioTap(SystemAudioTapInfo info);

// Diagnostic functions — isolate each step for crash debugging.
/// Step 1: Create a CATapDescription object. Returns non-NULL on success.
void *_Nullable CreateTapDescription(void);
/// Step 2: Call AudioHardwareCreateProcessTap. Returns the tapID (0 on failure).
AudioObjectID CreateProcessTapFromDescription(void *_Nonnull tapDescription);
/// Step 3: Create aggregate device from a tapID. Returns the aggregate device ID.
AudioDeviceID CreateAggregateDeviceFromTap(AudioObjectID tapID);
