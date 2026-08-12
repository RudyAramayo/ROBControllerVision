import ROBControlCore
import SwiftUI

struct OperatorSpeechPanel: View {
    @Bindable var model: RobotViewModel

    private var canSend: Bool {
        model.snapshot.connection.isReady
            && !model.operatorTextDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("VOICE & PUPPET SPEECH", systemImage: "waveform.and.mic")
                .font(.caption.bold())
                .foregroundStyle(.cyan)

            TextField("Talk or type what ROB should hear…", text: $model.operatorTextDraft, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)

            Picker("Spoken phrase", selection: $model.operatorTextMode) {
                Text("Command").tag(OperatorTextMode.command)
                Text("ROB Says It").tag(OperatorTextMode.puppetSpeech)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                Button(action: model.toggleVisionDictation) {
                    Label(
                        model.speechInput.isRecording ? "Stop" : "Dictate",
                        systemImage: model.speechInput.isRecording ? "stop.fill" : "mic.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(model.speechInput.isRecording ? .red : .blue)

                Button("Clear") { model.operatorTextDraft = "" }
                    .disabled(model.operatorTextDraft.isEmpty)
            }

            Text(model.speechInput.status)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("A completed dictation is sent automatically in the selected mode.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    model.sendOperatorText(as: .command)
                } label: {
                    Label("Send as Input", systemImage: "brain.head.profile")
                }
                .help("Process this exactly like text entered directly into Cerebro")

                Button {
                    model.sendOperatorText(as: .puppetSpeech)
                } label: {
                    Label("ROB Says It", systemImage: "speaker.wave.2.fill")
                }
                .help("Speak the text verbatim without interpreting it as a command")
            }
            .buttonStyle(.bordered)
            .disabled(!canSend)

            Text("Speech does not arm motion or bypass the physical emergency stop.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
