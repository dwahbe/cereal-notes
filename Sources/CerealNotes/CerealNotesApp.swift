import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct CerealNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var recordingState = RecordingState()
    @State private var storageSettings = StorageSettings()
    @State private var modelDownloadState: ModelDownloadState
    @State private var meetingDetectionService: MeetingDetectionService
    @State private var voiceProfileStore = VoiceProfileStore()

    init() {
        let recording = RecordingState()
        let storage = StorageSettings()
        let voices = VoiceProfileStore()
        let detector = MeetingDetectionService(recordingState: recording)
        let modelState = ModelDownloadState(transcriptionService: recording.transcriptionService)

        recording.voiceProfileStore = voices
        recording.onRecordingChange = { [weak detector] in detector?.recordingStateChanged() }
        detector.onRecordRequested = { [weak recording, weak storage] in
            guard let recording, let storage else { return }
            Task { await recording.start(storageDirectory: storage.storageLocation) }
        }

        _recordingState = State(initialValue: recording)
        _storageSettings = State(initialValue: storage)
        _modelDownloadState = State(initialValue: modelState)
        _meetingDetectionService = State(initialValue: detector)
        _voiceProfileStore = State(initialValue: voices)

        // Kick model download off at app launch, not when the popover first
        // opens — the banner lets users start recording without ever opening
        // the popover, so gating downloads on the popover's .task races the user.
        Task { @MainActor in await modelState.downloadIfNeeded() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(recordingState)
                .environment(storageSettings)
                .environment(modelDownloadState)
                .environment(meetingDetectionService)
                .environment(voiceProfileStore)
                .preferredColorScheme(.dark)
                .task {
                    await modelDownloadState.downloadIfNeeded()
                }
        } label: {
            Image(systemName: recordingState.isRecording ? "record.circle" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(voiceProfileStore)
                .environment(storageSettings)
                .environment(meetingDetectionService)
        }
    }
}
