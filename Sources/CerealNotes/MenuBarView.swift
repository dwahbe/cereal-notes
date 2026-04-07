import SwiftUI

struct MenuBarView: View {
    @Environment(RecordingState.self) private var recordingState
    @Environment(StorageSettings.self) private var storageSettings

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

        Button(action: { recordingState.start() }) {
            Label("Start Recording", systemImage: "record.circle")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .glassEffect()

        HStack {
            Text("Storage")
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: { storageSettings.pickFolder() }) {
                Text(storageSettings.storageLocationName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
        .font(.caption)
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
        .glassEffect()
    }
}
