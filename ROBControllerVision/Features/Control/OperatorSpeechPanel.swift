import ROBControlCore
import SwiftUI

struct OperatorSpeechPanel: View {
    @Bindable var model: RobotViewModel
    @FocusState private var editorIsFocused: Bool

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
                .focused($editorIsFocused)
                .submitLabel(.send)
                .onSubmit {
                    sendOperatorText(as: model.operatorTextMode)
                }

            HStack(spacing: 8) {
                speechControl(
                    "Command",
                    systemImage: "brain.head.profile",
                    isSelected: model.operatorTextMode == .command
                ) {
                    selectMode(.command)
                }
                speechControl(
                    "ROB Says It",
                    systemImage: "speaker.wave.2.fill",
                    isSelected: model.operatorTextMode == .puppetSpeech
                ) {
                    selectMode(.puppetSpeech)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Spoken phrase mode")

            HStack(spacing: 10) {
                speechControl(
                    model.speechInput.isStarting
                        ? "Starting…"
                        : model.speechInput.isRecording ? "Stop" : "Dictate",
                    systemImage: model.speechInput.isRecording ? "stop.fill" : "mic.fill",
                    isEnabled: !model.speechInput.isStarting,
                    isProminent: true,
                    tint: model.speechInput.isRecording ? .red : .blue
                ) {
                    editorIsFocused = false
                    model.toggleVisionDictation()
                }

                speechControl(
                    "Clear",
                    systemImage: "xmark",
                    isEnabled: !model.operatorTextDraft.isEmpty
                ) {
                    editorIsFocused = false
                    model.operatorTextDraft = ""
                }
            }

            Text(model.speechInput.status)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("A completed dictation is sent automatically in the selected mode.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                speechControl(
                    "Send as Input",
                    systemImage: "brain.head.profile",
                    isEnabled: canSend
                ) {
                    sendOperatorText(as: .command)
                }

                speechControl(
                    "ROB Says It",
                    systemImage: "speaker.wave.2.fill",
                    isEnabled: canSend
                ) {
                    sendOperatorText(as: .puppetSpeech)
                }
            }

            Text("Speech does not arm motion or bypass the physical emergency stop.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Material.thin)
        )
    }

    private func selectMode(_ mode: OperatorTextMode) {
        editorIsFocused = false
        model.operatorTextMode = mode
    }

    private func sendOperatorText(as mode: OperatorTextMode) {
        editorIsFocused = false
        // Let visionOS retire the remote TextField/keyboard session before the
        // control send updates observable state. This avoids the cross-UIWindow
        // conversion path that can trip a queue assertion on visionOS 26.5.
        Task { @MainActor in
            await Task.yield()
            model.sendOperatorText(as: mode)
        }
    }

    /// visionOS 26.5 can route SwiftUI Button and segmented-Picker feedback through a separate
    /// system UI window while TextField or dictation input is active. A direct spatial tap keeps
    /// this panel on its own interaction path while retaining button accessibility semantics.
    private func speechControl(
        _ title: String,
        systemImage: String,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        isProminent: Bool = false,
        tint: Color = .accentColor,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(isProminent ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        isProminent
                            ? tint.opacity(0.88)
                            : isSelected
                                ? Color.accentColor.opacity(0.28)
                                : Color.primary.opacity(0.08)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isSelected ? Color.accentColor.opacity(0.8) : Color.clear,
                                lineWidth: 1
                            )
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .opacity(isEnabled ? 1 : 0.42)
            .allowsHitTesting(isEnabled)
            .hoverEffect(.highlight)
            .onTapGesture {
                guard isEnabled else { return }
                action()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction {
                guard isEnabled else { return }
                action()
            }
    }
}
