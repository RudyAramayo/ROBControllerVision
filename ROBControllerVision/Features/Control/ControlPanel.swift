import ROBControlCore
import SwiftUI

struct ControlPanel: View {
    @Bindable var model: RobotViewModel

    private var controlsEnabled: Bool {
        model.snapshot.connection.isReady
            && model.snapshot.safety.isArmed
            && !model.snapshot.safety.emergencyStopIsLatched
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Robot Control")
                .font(.title2.bold())

            HStack {
                Label(
                    model.gameController.controllerName,
                    systemImage: model.gameController.isConnected ? "gamecontroller.fill" : "gamecontroller"
                )
                .lineLimit(1)
                Spacer()
                Circle()
                    .fill(model.gameController.deadManIsHeld ? .green : .secondary)
                    .frame(width: 10, height: 10)
            }

            Text(model.gameController.lastEventDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Speed limit")
                    Spacer()
                    Text(model.speedLimit, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                Slider(value: $model.speedLimit, in: 0.1...1.0)
            }

            VStack(spacing: 10) {
                HoldControlButton(title: "Forward", systemImage: "arrow.up", isEnabled: controlsEnabled) {
                    model.beginVirtualMotion(linear: 1, angular: 0)
                } onRelease: {
                    model.endVirtualMotion()
                }

                HStack(spacing: 10) {
                    HoldControlButton(title: "Left", systemImage: "arrow.left", isEnabled: controlsEnabled) {
                        model.beginVirtualMotion(linear: 0, angular: -1)
                    } onRelease: {
                        model.endVirtualMotion()
                    }

                    HoldControlButton(title: "Right", systemImage: "arrow.right", isEnabled: controlsEnabled) {
                        model.beginVirtualMotion(linear: 0, angular: 1)
                    } onRelease: {
                        model.endVirtualMotion()
                    }
                }

                HoldControlButton(title: "Reverse", systemImage: "arrow.down", isEnabled: controlsEnabled) {
                    model.beginVirtualMotion(linear: -1, angular: 0)
                } onRelease: {
                    model.endVirtualMotion()
                }
            }

            Button(action: model.toggleArmed) {
                Label(
                    model.snapshot.safety.isArmed ? "Disarm Motion" : "Arm Motion",
                    systemImage: model.snapshot.safety.isArmed ? "lock.open.fill" : "lock.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.snapshot.safety.isArmed ? .orange : .blue)
            .disabled(
                !model.snapshot.connection.isReady
                    || model.snapshot.safety.emergencyStopIsLatched
            )

            Button(role: .destructive, action: model.emergencyStop) {
                Label("EMERGENCY STOP", systemImage: "stop.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            if model.snapshot.safety.emergencyStopIsLatched {
                Button("Reset Emergency Stop", action: model.resetEmergencyStop)
                    .frame(maxWidth: .infinity)
            }

            Text("Software controls supplement — and never replace — the robot's physical emergency stop.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct HoldControlButton: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var isPressed = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(
                isPressed ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.16),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .opacity(isEnabled ? 1 : 0.45)
            .allowsHitTesting(isEnabled)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        onPress()
                    }
                    .onEnded { _ in
                        isPressed = false
                        onRelease()
                    }
            )
            .onDisappear {
                if isPressed {
                    isPressed = false
                    onRelease()
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Hold to command motion; release to stop")
    }
}
