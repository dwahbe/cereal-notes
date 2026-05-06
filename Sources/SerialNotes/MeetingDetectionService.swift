import AppKit
import CoreAudio
import Foundation

struct DetectedMeeting: Equatable {
    let appName: String
    let bundleIdentifier: String
    let detectedAt: Date
}

@MainActor @Observable
final class MeetingDetectionService {
    nonisolated static let knownMeetingApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams": "Microsoft Teams",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.webex.meetingmanager": "Webex",
        "com.hnc.Discord": "Discord",
    ]

    private(set) var detectedMeeting: DetectedMeeting?

    @ObservationIgnored var onRecordRequested: (() -> Void)?

    @ObservationIgnored private weak var recordingState: RecordingState?
    @ObservationIgnored private let banner = MeetingBannerController()
    @ObservationIgnored private var runningMeetingApps: Set<String> = []
    @ObservationIgnored private var activationOrder: [String] = []  // most recent first
    @ObservationIgnored private var suppressedBundleIDs: Set<String> = []
    @ObservationIgnored private var micActive: Bool = false
    @ObservationIgnored private var lastNotifiedBundleID: String?
    // Attribution is sticky while mic is continuously active — see reevaluate() notes.
    @ObservationIgnored private var lockedBundleID: String?
    @ObservationIgnored private var userRejectedThisWindow: Bool = false
    // When true, detection is paused — used while voice enrollment holds the mic
    // so we don't fire a phantom "meeting detected" banner from our own recording.
    @ObservationIgnored private var isSuspended: Bool = false

    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var currentInputDeviceID: AudioDeviceID = kAudioObjectUnknown
    @ObservationIgnored private var micListenerBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    init(recordingState: RecordingState) {
        self.recordingState = recordingState
        banner.onRecord = { [weak self] in
            self?.onRecordRequested?()
        }
        banner.onDismiss = { [weak self] in
            self?.dismissCurrent()
        }
        seedRunningApps()
        registerWorkspaceObservers()
        registerDefaultDeviceListener()
        rebindMicListener()
        reevaluate()
    }

    // Owned by SwiftUI @State at the app root, so this never deinits in practice.
    // Skip teardown rather than fight the nonisolated-deinit rules.

    // MARK: - Public API

    func dismissCurrent() {
        if let locked = lockedBundleID {
            suppressedBundleIDs.insert(locked)
        } else if let current = detectedMeeting {
            suppressedBundleIDs.insert(current.bundleIdentifier)
        }
        // Stay silent for the rest of this mic-active window. Don't hunt for a
        // different meeting app — mic activity is driven by the rejected one.
        userRejectedThisWindow = true
        reevaluate()
    }

    /// Pause detection — used while voice enrollment holds the mic so we don't
    /// trigger a false "meeting detected" prompt.
    func suspendDetection() {
        isSuspended = true
        clearDetected()
    }

    /// Resume detection after `suspendDetection()`.
    func resumeDetection() {
        isSuspended = false
        // CoreAudio takes a moment to report `micActive=false` after the
        // enrollment engine stops. If we'd reevaluate right now with the mic
        // still reported active, we'd pick whatever meeting app happens to be
        // running and fire a false positive. Treat the remainder of this mic
        // window as implicitly dismissed — the detector will clear the flag
        // the next time the mic genuinely goes inactive.
        if micActive {
            userRejectedThisWindow = true
        }
        reevaluate()
    }

    func recordingStateChanged() {
        // User stopped recording while still in a call (mic still active) → treat
        // as an implicit dismiss so we don't immediately re-prompt. They made a
        // choice to stop.
        if recordingState?.isRecording == false, micActive {
            if let locked = lockedBundleID {
                suppressedBundleIDs.insert(locked)
            }
            userRejectedThisWindow = true
        }
        reevaluate()
    }

    // MARK: - NSWorkspace

    private func seedRunningApps() {
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier, Self.knownMeetingApps[bundleID] != nil {
                runningMeetingApps.insert(bundleID)
            }
        }
        if let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           Self.knownMeetingApps[frontBundle] != nil {
            recordActivation(frontBundle)
        }
    }

    private func recordActivation(_ bundleID: String) {
        activationOrder.removeAll { $0 == bundleID }
        activationOrder.insert(bundleID, at: 0)
    }

    private func registerWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter

        let launch = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let bundleID = app.bundleIdentifier,
                Self.knownMeetingApps[bundleID] != nil
            else { return }
            MainActor.assumeIsolated {
                self?.runningMeetingApps.insert(bundleID)
                self?.reevaluate()
            }
        }

        let terminate = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let bundleID = app.bundleIdentifier
            else { return }
            MainActor.assumeIsolated {
                self?.runningMeetingApps.remove(bundleID)
                self?.suppressedBundleIDs.remove(bundleID)
                self?.activationOrder.removeAll { $0 == bundleID }
                self?.reevaluate()
            }
        }

        let activate = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let bundleID = app.bundleIdentifier,
                Self.knownMeetingApps[bundleID] != nil
            else { return }
            MainActor.assumeIsolated {
                self?.recordActivation(bundleID)
                self?.reevaluate()
            }
        }

        workspaceObservers = [launch, terminate, activate]
    }

    // MARK: - CoreAudio

    nonisolated private static func makeMicRunningAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    nonisolated private static func makeDefaultInputDeviceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func registerDefaultDeviceListener() {
        var addr = Self.makeDefaultInputDeviceAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.rebindMicListener()
                }
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        if status == noErr {
            defaultDeviceListenerBlock = block
        }
    }

    private func rebindMicListener() {
        // Remove existing listener on old device.
        if let oldBlock = micListenerBlock, currentInputDeviceID != kAudioObjectUnknown {
            var addr = Self.makeMicRunningAddress()
            AudioObjectRemovePropertyListenerBlock(
                currentInputDeviceID, &addr, DispatchQueue.main, oldBlock)
        }
        micListenerBlock = nil
        currentInputDeviceID = kAudioObjectUnknown

        guard let newDeviceID = Self.defaultInputDeviceID() else {
            micActive = false
            reevaluate()
            return
        }

        currentInputDeviceID = newDeviceID
        micActive = Self.readIsRunningSomewhere(deviceID: newDeviceID)

        var addr = Self.makeMicRunningAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            let active = Self.readIsRunningSomewhere(deviceID: newDeviceID)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.micActive = active
                    self?.reevaluate()
                }
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            newDeviceID, &addr, DispatchQueue.main, block)
        if status == noErr {
            micListenerBlock = block
        }
        reevaluate()
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = makeDefaultInputDeviceAddress()
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func readIsRunningSomewhere(deviceID: AudioDeviceID) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = makeMicRunningAddress()
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    // MARK: - Fusion

    private func selectMeetingApp() -> String? {
        func available(_ bundleID: String) -> Bool {
            runningMeetingApps.contains(bundleID) && !suppressedBundleIDs.contains(bundleID)
        }

        // 1. Frontmost known meeting app wins — strongest signal of user intent.
        if let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           available(frontBundle) {
            return frontBundle
        }

        // 2. Otherwise prefer the most recently activated known meeting app.
        if let recent = activationOrder.first(where: available) {
            return recent
        }

        // 3. Deterministic fallback: alphabetical by bundle ID (Set order is undefined).
        return runningMeetingApps.filter { !suppressedBundleIDs.contains($0) }.sorted().first
    }

    // State machine for prompt attribution:
    //   · While mic is continuously active, we LOCK to one bundle ID — the one
    //     present at mic-activation time. Frontmost/activation changes do NOT
    //     re-attribute (avoids "Slack call detected" when Zoom warm-holds the
    //     mic after a call ends and the user switches to Slack).
    //   · If the locked app terminates mid-window, clear detection but do not
    //     hunt for a replacement — the mic is still warm from the dead app, not
    //     from any newly-candidate one.
    //   · Dismiss and Stop-Recording set `userRejectedThisWindow` so no further
    //     prompts fire until the mic cycles (signals end-of-call).
    //   · Mic inactive is the only reset: clears lock, suppression, and rejection.
    private func reevaluate() {
        if isSuspended {
            clearDetected()
            return
        }

        if recordingState?.isRecording == true {
            clearDetected()
            return
        }

        if !micActive {
            suppressedBundleIDs.removeAll()
            lastNotifiedBundleID = nil
            lockedBundleID = nil
            userRejectedThisWindow = false
            clearDetected()
            return
        }

        // Mic is active. If the user already rejected for this window, stay quiet.
        if userRejectedThisWindow {
            clearDetected()
            return
        }

        // Sticky attribution: if we locked onto an app earlier in this window,
        // keep it (even if something else became frontmost).
        if let locked = lockedBundleID {
            if runningMeetingApps.contains(locked),
               let appName = Self.knownMeetingApps[locked] {
                applyDetection(bundleID: locked, appName: appName)
                return
            }
            // Locked app quit mid-window. Don't re-attribute — wait for mic cycle.
            lockedBundleID = nil
            clearDetected()
            return
        }

        // No prior lock: this is the start of a mic-active window (or a fresh
        // reevaluate after a reset). Pick once and lock.
        if let bundleID = selectMeetingApp(), let appName = Self.knownMeetingApps[bundleID] {
            lockedBundleID = bundleID
            applyDetection(bundleID: bundleID, appName: appName)
        } else {
            clearDetected()
        }
    }

    private func applyDetection(bundleID: String, appName: String) {
        if detectedMeeting?.bundleIdentifier != bundleID {
            detectedMeeting = DetectedMeeting(
                appName: appName,
                bundleIdentifier: bundleID,
                detectedAt: Date()
            )
        }
        if lastNotifiedBundleID != bundleID {
            lastNotifiedBundleID = bundleID
            banner.show(appName: appName)
        }
    }

    private func clearDetected() {
        if detectedMeeting != nil {
            detectedMeeting = nil
        }
        if lastNotifiedBundleID != nil {
            lastNotifiedBundleID = nil
            banner.hide()
        }
    }
}
