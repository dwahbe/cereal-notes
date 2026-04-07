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
