import ROBControlCore
import SwiftUI

struct ConnectionStatusView: View {
    @Bindable var model: RobotViewModel

    private var phaseColor: Color {
        switch model.snapshot.connection.phase {
        case .connected: .green
        case .connecting, .handshaking, .disconnecting: .orange
        case .failed: .red
        case .disconnected: .secondary
        }
    }

    private var connectionTitle: String {
        switch model.snapshot.connection.phase {
        case .connected: model.snapshot.connection.handshake?.robotName ?? "Connected"
        case .connecting: "Connecting"
        case .handshaking: "Handshaking"
        case .disconnecting: "Disconnecting"
        case .failed: "Connection failed"
        case .disconnected: "Not connected"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(phaseColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(connectionTitle)
                        .font(.headline)
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if let service = model.snapshot.connection.endpoint?.serviceType {
                    Text(service)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 12) {
                Picker("Endpoint", selection: $model.connectionDestination) {
                    ForEach(RobotConnectionDestination.allCases) { destination in
                        Text(destination.label).tag(destination)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .disabled(!model.canChangeConnectionDestination)

                Button {
                    model.showsPairingSheet = true
                } label: {
                    Label(
                        model.hasInstalledCerebroCredential ? "Credential" : "Pair Cerebro",
                        systemImage: model.cerebroCredentialIsVerified
                            ? "checkmark.shield"
                            : "key"
                    )
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(model.connectionButtonTitle, action: model.toggleConnection)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canToggleConnection)
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .sheet(isPresented: $model.showsPairingSheet) {
            CerebroPairingSheet(model: model)
        }
    }
}
