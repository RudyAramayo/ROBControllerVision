import SwiftUI

struct CerebroPairingSheet: View {
    @Bindable var model: RobotViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsReplaceConfirmation = false
    @State private var showsForgetConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Cerebro enrollment") {
                    Text(
                        "In Cerebro, open Manage Paired Devices, choose Pair ROBController, and issue a new credential named Apple Vision Pro. Each controller needs its own credential."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    SecureField("ROBCTL2:…", text: $model.pairingCodeDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()

                    Button(
                        model.hasInstalledCerebroCredential
                            ? "Replace installed credential"
                            : "Install pairing code"
                    ) {
                        if model.hasInstalledCerebroCredential {
                            showsReplaceConfirmation = true
                        } else {
                            model.installPairingCode()
                        }
                    }
                    .disabled(
                        model.pairingCodeDraft.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    )
                }

                Section("Status") {
                    LabeledContent("Vision Pro", value: model.cerebroCredentialStatusLabel)
                    if let pairedCerebroDescription = model.pairedCerebroDescription {
                        LabeledContent("Credential", value: pairedCerebroDescription)
                    }
                    Text(model.pairingStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if model.hasInstalledCerebroCredential {
                    Section {
                        Button("Forget pairing", role: .destructive) {
                            showsForgetConfirmation = true
                        }
                    } footer: {
                        Text(
                            "Forgetting removes only this Vision Pro's local Keychain item. Revoke the device separately in Cerebro if the credential should no longer be trusted."
                        )
                    }
                }
            }
            .navigationTitle("Pair with Cerebro")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 520)
        .onDisappear {
            model.clearPairingCodeDraft()
        }
        .confirmationDialog(
            "Replace the installed Cerebro credential?",
            isPresented: $showsReplaceConfirmation,
            titleVisibility: .visible
        ) {
            Button("Replace credential", role: .destructive) {
                model.installPairingCode()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current device secret cannot be recovered after replacement.")
        }
        .confirmationDialog(
            "Forget this Cerebro credential?",
            isPresented: $showsForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget credential", role: .destructive) {
                model.forgetPairing()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local secret only. Revoke the device separately in Cerebro.")
        }
    }
}
