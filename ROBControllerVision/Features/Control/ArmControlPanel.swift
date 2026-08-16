import Foundation
import ROBControlCore
import SwiftUI

struct ArmControlPanel: View {
    @Bindable var model: RobotViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingEnableArm: RobotArmSide?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        safetyBoundary
                        pairedControllerJog
                        ForEach(RobotArmSide.allCases, id: \.self) { arm in
                            armLane(arm)
                        }
                        gripperControl
                        priorityHold
                    }
                    .padding(24)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 820)
        .onDisappear(perform: model.armControlPanelDidDisappear)
        .confirmationDialog(
            "Enable supervised \(pendingEnableArm?.rawValue ?? "Amber") arm control?",
            isPresented: Binding(
                get: { pendingEnableArm != nil },
                set: { if !$0 { pendingEnableArm = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Enable Arm Control") {
                guard let arm = pendingEnableArm else { return }
                pendingEnableArm = nil
                model.toggleArmControl(for: arm)
            }
            Button("Cancel", role: .cancel) { pendingEnableArm = nil }
        } message: {
            Text(
                "Drive control will be disabled. Confirm the arm is supported, the workspace is clear, and the physical E-stop operator is ready. Vision Pro never activates the arm or changes actuator mode."
            )
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "move.3d")
                .font(.title2)
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text("Supervised Dual Amber Arm Control")
                    .font(.title2.bold())
                Text("Independent measured joint lanes • release always requests hold")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding(20)
    }

    private var safetyBoundary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("PHYSICAL E-STOP REMAINS AUTHORITATIVE", systemImage: "exclamationmark.octagon.fill")
                .font(.caption.bold())
                .foregroundStyle(.red)
            Text(
                "Arm activation and position-mode changes stay in Cerebro diagnostics because mode transitions can remove holding torque. Each lane requests only bounded motion after Cerebro grants that arm a time-limited authority."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private var pairedControllerJog: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("PAIRED CONTROLLER JOG", systemImage: "gamecontroller.fill")
                    .font(.headline)
                Spacer()
                Text(model.pairedControllerJogIsActive ? "ACTIVE" : "INACTIVE")
                    .font(.caption.bold())
                    .foregroundStyle(model.pairedControllerJogIsActive ? .green : .secondary)
            }
            HStack(spacing: 14) {
                statusChip(
                    "Left Sense",
                    passes: model.gameController.leftSpatialControllerIsConnected,
                    detail: model.gameController.leftSpatialGripIsHeld ? "grip held" : "release"
                )
                statusChip(
                    "Right Sense",
                    passes: model.gameController.rightSpatialControllerIsConnected,
                    detail: model.gameController.rightSpatialGripIsHeld ? "grip held" : "release"
                )
                statusChip(
                    "Dual dead-man",
                    passes: model.pairedSpatialDeadManIsHeld,
                    detail: "both grips"
                )
            }
            Text(
                "After both arms pass preflight, press and hold both grips to jog each arm's selected joint with its matching vertical thumbstick. The 0.15 dead zone and measured 0.08-radian / 0.20-radian-per-second limits remain enforced. This is joint jogging, not controller-pose IK. Release either grip to hold both arms while retaining authority; disconnects, stale input, or preflight failures clear both local latches."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }

    private func armLane(_ arm: RobotArmSide) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(
                    "\(arm.rawValue.uppercased()) ARM",
                    systemImage: arm == .left ? "arrow.left.circle.fill" : "arrow.right.circle.fill"
                )
                .font(.title3.bold())
                Spacer()
                Button("Initialize from measured pose") {
                    model.initializeArmDraft(for: arm)
                }
                .buttonStyle(.bordered)
                .disabled(
                    !model.canInitializeArmDraft(for: arm)
                        || model.armDeadManControlIsActive(for: arm)
                )
            }

            preflight(for: arm)
            jointEditor(for: arm)
            motionControls(for: arm)
            feedback(for: arm)
        }
        .padding(16)
        .background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
    }

    private func preflight(for arm: RobotArmSide) -> some View {
        HStack(spacing: 12) {
            statusChip(
                "Cerebro v2",
                passes: model.supportsPhysicalArmControl,
                detail: model.supportsPhysicalArmControl ? "execution profile" : "unavailable"
            )
            statusChip(
                "Feedback",
                passes: model.armTelemetryIsFresh(for: arm),
                detail: telemetryAgeText(for: arm)
            )
            statusChip(
                "Position mode",
                passes: model.armModesArePosition(for: arm),
                detail: modeText(for: arm)
            )
            statusChip(
                "Authority",
                passes: model.armAuthorityIsGranted(for: arm),
                detail: authorityText(for: arm)
            )
        }
    }

    private func statusChip(_ title: String, passes: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: passes ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(passes ? .green : .orange)
            Text(detail)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func jointEditor(for arm: RobotArmSide) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Joint target draft")
                    .font(.headline)
                Spacer()
                Text("One selected joint per lane • ±0.08 rad")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(0 ..< RobotArmTargetIntent.jointCount, id: \.self) { joint in
                jointRow(arm: arm, joint: joint)
            }
        }
    }

    private func jointRow(arm: RobotArmSide, joint: Int) -> some View {
        let measured = model.armMeasuredState(for: arm)?.positionsRadians[safe: joint]
        let draft = model.armDraftPositions(for: arm)[safe: joint]
        let isSelected = model.selectedArmJoint(for: arm) == joint
        return HStack(spacing: 12) {
            Button {
                model.setSelectedArmJoint(joint, for: arm)
            } label: {
                Label("J\(joint + 1)", systemImage: isSelected ? "record.circle.fill" : "circle")
                    .frame(width: 58, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(
                model.armDraftPositions(for: arm).isEmpty
                    || model.armDeadManControlIsActive(for: arm)
            )

            Text(angleText(measured))
                .font(.caption.monospacedDigit())
                .frame(width: 68, alignment: .trailing)
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { draft ?? measured ?? 0 },
                    set: { model.updateArmDraft(for: arm, joint: joint, value: $0) }
                ),
                in: model.armDraftBounds(for: arm, joint: joint)
            )
            .disabled(
                !isSelected || model.armDraftPositions(for: arm).isEmpty
                    || model.armDeadManControlIsActive(for: arm)
            )

            Text(angleText(draft))
                .font(.caption.monospacedDigit().bold())
                .frame(width: 68, alignment: .trailing)
        }
    }

    private func motionControls(for arm: RobotArmSide) -> some View {
        VStack(spacing: 10) {
            Button {
                if model.armHasServerAuthority(arm) || model.armAuthorityIsPending(arm) {
                    model.toggleArmControl(for: arm)
                } else {
                    pendingEnableArm = arm
                }
            } label: {
                Label(
                    model.armHasServerAuthority(arm)
                        ? "Disable \(arm.rawValue.capitalized) Arm Control"
                        : model.armAuthorityIsPending(arm)
                            ? "Cancel / Release \(arm.rawValue.capitalized) Authority"
                            : "Enable \(arm.rawValue.capitalized) Arm Control",
                    systemImage: model.armHasServerAuthority(arm) ? "lock.open.fill" : "lock.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.armHasServerAuthority(arm) ? .orange : .blue)
            .disabled(
                !model.supportsPhysicalArmControl
                    || model.snapshot.safety.emergencyStopIsLatched
            )

            ArmHoldButton(
                title: "HOLD TO MOVE \(arm.rawValue.uppercased()) SELECTED JOINT",
                isEnabled: (
                    model.canBeginArmMotion(for: arm)
                        || model.armDeadManControlIsActive(for: arm)
                ) && !model.pairedControllerJogIsActive,
                onPress: { model.beginArmMotion(for: arm) },
                onRelease: { model.endArmMotion(for: arm) }
            )
        }
    }

    private func feedback(for arm: RobotArmSide) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.armControlStatusMessage(for: arm), systemImage: "waveform.path.ecg")
                .font(.subheadline.weight(.medium))
            if let disposition = model.armControlState(for: arm).lastDisposition {
                Text(
                    disposition.disposition.rawValue.replacingOccurrences(of: "_", with: " ")
                        + (disposition.maximumErrorRadians.map {
                            " • max error \($0.formatted(.number.precision(.fractionLength(3)))) rad"
                        } ?? "")
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private var gripperControl: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Gripper")
                    .font(.headline)
                Picker("Gripper arm", selection: $model.selectedArm) {
                    ForEach(RobotArmSide.allCases, id: \.self) { arm in
                        Text(arm.rawValue.capitalized).tag(arm)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                Spacer()
                Text(gripperCalibrationText)
                    .font(.caption.bold())
                    .foregroundStyle(
                        model.selectedGripperState?.calibrationState
                            == .commandAcceptedUnverified ? .orange : .red
                    )
            }

            HStack {
                Text("Hold intensity")
                Slider(
                    value: Binding(
                        get: { Double(model.selectedGripperForce) },
                        set: { model.selectedGripperForce = Int($0.rounded()) }
                    ),
                    in: Double(RobotGripperCommandIntent.forceRange.lowerBound)
                        ... Double(RobotGripperCommandIntent.forceRange.upperBound),
                    step: 1
                )
                Text("\(model.selectedGripperForce)")
                    .font(.body.monospacedDigit().bold())
                    .frame(width: 32, alignment: .trailing)
            }

            HStack(spacing: 12) {
                Button("Release") { model.operateSelectedGripper(.release) }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
                Button("Hold") { model.operateSelectedGripper(.hold) }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                Button("Stop unavailable") {}
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
                    .disabled(true)
            }
            .disabled(!model.selectedGripperCanOperate || !model.gameController.deadManIsHeld)

            Text(
                "Hold both controller grip buttons. The matching index trigger holds; releasing that trigger releases. Amber reports command dispatch only—not measured opening, force, or completion."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text(model.gripperControlStatusMessage)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }

    private var priorityHold: some View {
        Button(role: .destructive) {
            model.requestPriorityHoldBoth()
        } label: {
            Label("PRIORITY HOLD BOTH ARMS", systemImage: "hand.raised.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(!model.snapshot.connection.isReady)
    }

    private var gripperCalibrationText: String {
        guard let state = model.selectedGripperState else { return "No gateway state" }
        switch state.calibrationState {
        case .required: return "Calibration required"
        case .commandAcceptedUnverified: return "Calibration accepted · unverified"
        }
    }

    private func telemetryAgeText(for arm: RobotArmSide) -> String {
        guard let age = model.armTelemetryAgeMilliseconds(for: arm) else { return "no sample" }
        return "\(age.formatted(.number.precision(.fractionLength(0)))) ms"
    }

    private func modeText(for arm: RobotArmSide) -> String {
        guard let modes = model.armMeasuredState(for: arm)?.modes else { return "unknown" }
        return modes.map(String.init).joined(separator: ",")
    }

    private func authorityText(for arm: RobotArmSide) -> String {
        let control = model.armControlState(for: arm)
        if control.pendingAuthorityRequestID != nil { return "pending" }
        guard let authority = control.authorityState else { return "not requested" }
        if authority.state == .granted {
            return "\(max(0, Int(authority.expiresAt.timeIntervalSinceNow))) s"
        }
        return authority.state.rawValue
    }

    private func angleText(_ radians: Double?) -> String {
        guard let radians else { return "—" }
        return "\((radians * 180 / .pi).formatted(.number.precision(.fractionLength(1))))°"
    }
}

private struct ArmHoldButton: View {
    let title: String
    let isEnabled: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var isPressed = false

    var body: some View {
        Label(title, systemImage: isPressed ? "hand.point.up.left.fill" : "hand.point.up.left")
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(
                isPressed ? Color.green.opacity(0.75) : Color.green.opacity(0.18),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .opacity(isEnabled ? 1 : 0.4)
            .allowsHitTesting(isEnabled)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed, isEnabled else { return }
                        isPressed = true
                        onPress()
                    }
                    .onEnded { _ in releaseIfNeeded() }
            )
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { releaseIfNeeded() }
            }
            .onDisappear(perform: releaseIfNeeded)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Keep holding to permit bounded arm motion; release to hold position")
    }

    private func releaseIfNeeded() {
        guard isPressed else { return }
        isPressed = false
        onRelease()
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
