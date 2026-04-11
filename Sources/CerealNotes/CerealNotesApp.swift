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

    init() {
        let recording = RecordingState()
        _recordingState = State(initialValue: recording)
        _storageSettings = State(initialValue: StorageSettings())
        _modelDownloadState = State(initialValue: ModelDownloadState(
            transcriptionService: recording.transcriptionService
        ))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(recordingState)
                .environment(storageSettings)
                .environment(modelDownloadState)
                .preferredColorScheme(.dark)
                .task {
                    await modelDownloadState.downloadIfNeeded()
                }
        } label: {
            Image(systemName: recordingState.isRecording ? "record.circle" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
