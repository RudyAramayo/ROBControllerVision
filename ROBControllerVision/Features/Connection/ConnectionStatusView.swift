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
                    .lineLimit(1)
            }

            Spacer()

            if let service = model.snapshot.connection.endpoint?.serviceType {
                Text(service)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Button(
                model.snapshot.connection.phase == .connected ? "Disconnect" : "Connect Simulator",
                action: model.toggleConnection
            )
            .buttonStyle(.borderedProminent)
            .disabled(model.snapshot.connection.phase == .disconnecting)
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
