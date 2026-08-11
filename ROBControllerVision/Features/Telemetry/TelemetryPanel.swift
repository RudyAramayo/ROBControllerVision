import ROBControlCore
import SwiftUI

struct TelemetryPanel: View {
    enum Layout {
        case horizontal
        case vertical
    }

    let snapshot: RobotSessionSnapshot
    var layout: Layout = .horizontal

    var body: some View {
        Group {
            if layout == .vertical {
                VStack(alignment: .leading, spacing: 18) { telemetryItems }
            } else {
                HStack(spacing: 28) { telemetryItems }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var telemetryItems: some View {
        telemetryItem(
            title: "Battery",
            value: snapshot.telemetry.map { $0.batteryLevel.formatted(.percent.precision(.fractionLength(0))) }
                ?? "—",
            systemImage: "battery.75percent"
        )
        telemetryItem(
            title: "Position",
            value: snapshot.telemetry.map {
                "\($0.pose.xMeters.formatted(.number.precision(.fractionLength(2)))), \($0.pose.yMeters.formatted(.number.precision(.fractionLength(2)))) m"
            } ?? "—",
            systemImage: "location.fill"
        )
        telemetryItem(
            title: "Velocity",
            value: snapshot.telemetry.map {
                "\($0.linearVelocity.formatted(.number.precision(.fractionLength(2)))) m/s"
            } ?? "—",
            systemImage: "speedometer"
        )
        telemetryItem(
            title: "Safety",
            value: snapshot.safety.inhibitReason?.description ?? "Motion active",
            systemImage: snapshot.safety.inhibitReason == nil ? "checkmark.shield.fill" : "shield.fill"
        )
    }

    private func telemetryItem(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
        }
    }
}
