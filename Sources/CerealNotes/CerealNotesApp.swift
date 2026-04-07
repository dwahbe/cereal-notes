import SwiftUI

@main
struct CerealNotesApp: App {
    @State private var recordingState = RecordingState()
    @State private var storageSettings = StorageSettings()

    init() {
        NSApp.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(recordingState)
                .environment(storageSettings)
                .preferredColorScheme(.dark)
        } label: {
            Image(systemName: recordingState.isRecording ? "record.circle" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
