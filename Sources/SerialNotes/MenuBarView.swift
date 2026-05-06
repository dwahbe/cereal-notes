import SwiftUI

struct MenuBarView: View {
    @Environment(RecordingState.self) private var recordingState
    @Environment(StorageSettings.self) private var storageSettings
    @Environment(ModelDownloadState.self) private var modelDownloadState
    @Environment(MeetingDetectionService.self) private var meetingDetectionService
    @Environment(\.openSettings) private var openSettings

    private var modelsReady: Bool {
        if case .ready = modelDownloadState.status { return true }
        return false
    }

    private func showSettings() {
        // .accessory apps don't front their Settings window automatically.
        // Match the pattern used by StorageSettings.pickFolder(): flip to
        // .regular, activate, then flip back once the window is dismissed.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        openSettings()
    }

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 16) {
                if recordingState.isRecording {
                    recordingContent
                } else {
                    idleContent
                }
            }
            .padding(20)
            .frame(width: 280)
            .animation(.default, value: recordingState.isRecording)
        }
        // Keep controls bright when Settings (or any other window) is key —
        // otherwise the popover renders as an inactive window and the
        // .glassProminent button washes out to near-white.
        .environment(\.controlActiveState, .active)
    }

    // MARK: - Idle

    @ViewBuilder
    private var idleContent: some View {
        HStack {
            Image(systemName: "waveform.circle")
                .font(.title2)
            Text("Cereal Notes")
                .font(.headline)
            Spacer()
            Button(action: showSettings) {
                Image(systemName: "gearshape")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }

        switch modelDownloadState.status {
        case .downloading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading models…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text("Model error: \(message)")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        default:
            EmptyView()
        }

        if let meeting = meetingDetectionService.detectedMeeting, modelsReady {
            VStack(spacing: 8) {
                Text("\(meeting.appName) call detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Dismiss") { meetingDetectionService.dismissCurrent() }
                        .controlSize(.large)
                        .buttonStyle(.glass)
                    Button(action: {
                        Task { await recordingState.start(storageDirectory: storageSettings.storageLocation) }
                    }) {
                        Label("Record", systemImage: "record.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.glassProminent)
                }
            }
        } else {
            Button(action: {
                Task { await recordingState.start(storageDirectory: storageSettings.storageLocation) }
            }) {
                Label("Start Recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.glassProminent)
            .disabled(!modelsReady)
        }

        if let error = recordingState.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        Button(action: { storageSettings.pickFolder() }) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Storage Location")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(storageSettings.storageLocationName)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.glass)
    }

    // MARK: - Recording

    @ViewBuilder
    private var recordingContent: some View {
        HStack {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text("Recording")
                .font(.headline)
        }

        Text(recordingState.formattedElapsedTime)
            .font(.system(.title, design: .monospaced))
            .contentTransition(.numericText())

        livePartialView

        Button(action: { recordingState.stop() }) {
            Label("Stop Recording", systemImage: "stop.circle")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.glassProminent)

        if let error = recordingState.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var livePartialView: some View {
        let mic = recordingState.livePartialMic
        let system = recordingState.livePartialSystem
        if !mic.isEmpty || !system.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !mic.isEmpty {
                    partialLine(speaker: "You", text: mic)
                }
                if !system.isEmpty {
                    partialLine(speaker: "Them", text: system)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }

    private func partialLine(speaker: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(speaker)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
