import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(VoiceProfileStore.self) private var voiceStore
    @Environment(StorageSettings.self) private var storageSettings

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }
            VoicesSettingsTab()
                .tabItem { Label("Voices", systemImage: "person.wave.2") }
        }
        .frame(width: 520, height: 420)
        .background(SettingsWindowChrome())
    }
}

/// Watches the hosting NSWindow and returns the app to `.accessory` activation
/// policy once Settings closes. Without this, clicking the gear flips us to
/// `.regular` and we'd stay there after the window goes away — putting the
/// app into the Dock and Cmd-Tab until relaunched.
private struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = WindowCloseObserver()
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowCloseObserver: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    @objc private func windowWillClose(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Voices Tab

private struct VoicesSettingsTab: View {
    @Environment(VoiceProfileStore.self) private var voiceStore
    @Environment(MeetingDetectionService.self) private var meetingDetector
    @State private var recorder = VoiceEnrollmentRecorder()
    @State private var showingEnrollmentFlow = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                yourVoiceRow
            } header: {
                Text("Your Voice")
            } footer: {
                Text("Used to recognize you in future meetings. Recorded locally. Nothing leaves your machine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if voiceStore.otherProfiles.isEmpty {
                    Text("You haven't named anyone yet. After a meeting, you can name the people Cereal Notes detected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(voiceStore.otherProfiles) { profile in
                        OtherProfileRow(profile: profile) { deleteProfile(profile) }
                    }
                }
            } header: {
                Text("Known People")
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showingEnrollmentFlow) {
            VoiceEnrollmentFlowView(
                recorder: recorder,
                voiceStore: voiceStore,
                onDismiss: { showingEnrollmentFlow = false }
            )
        }
        .onAppear {
            let detector = meetingDetector
            recorder.onSuspendDetection = { detector.suspendDetection() }
            recorder.onResumeDetection = { detector.resumeDetection() }
        }
    }

    // MARK: - Your Voice Row

    @ViewBuilder
    private var yourVoiceRow: some View {
        if let profile = voiceStore.yourProfile {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.body.weight(.medium))
                    Text("Voice profile saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Re-record") { showingEnrollmentFlow = true }
                Button(role: .destructive) {
                    try? voiceStore.delete(profile)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not set")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text("Record a short sample so we can label you by name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Set Up") { showingEnrollmentFlow = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func deleteProfile(_ profile: VoiceProfile) {
        do {
            try voiceStore.delete(profile)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Row

private struct OtherProfileRow: View {
    let profile: VoiceProfile
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "person.circle")
                .foregroundStyle(.secondary)
            Text(profile.name)
            Spacer()
            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    @Environment(StorageSettings.self) private var storageSettings
    @Environment(VoiceProfileStore.self) private var voiceStore

    var body: some View {
        Form {
            Section("Storage") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(storageSettings.storageLocationName)
                            .font(.body)
                        Text(storageSettings.storageLocation.path(percentEncoded: false))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Change…") { storageSettings.pickFolder() }
                }
            }

            Section("Voice Profiles") {
                Button("Reveal in Finder") { voiceStore.revealInFinder() }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
