import SwiftUI

struct MenuBarView: View {
    @Environment(RecordingState.self) private var recordingState
    @Environment(StorageSettings.self) private var storageSettings
    @Environment(ModelDownloadState.self) private var modelDownloadState

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
    }

    // MARK: - Idle

    @ViewBuilder
    private var idleContent: some View {
        HStack {
            Image(systemName: "waveform.circle")
                .font(.title2)
            Text("Cereal Notes")
                .font(.headline)
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

        Button(action: {
            Task { await recordingState.start(storageDirectory: storageSettings.storageLocation) }
        }) {
            Label("Start Recording", systemImage: "record.circle")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.glassProminent)
        .disabled({
            if case .ready = modelDownloadState.status { return false }
            return true
        }())

        if let error = recordingState.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
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

        Button(action: { recordingState.stop() }) {
            Label("Stop Recording", systemImage: "stop.circle")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.glassProminent)
    }
}
