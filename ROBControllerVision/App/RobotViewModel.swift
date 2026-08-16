import Foundation
import Observation
import ROBCerebroTransport
import ROBControlCore
import ROBVideoPipeline

enum RobotConnectionDestination: String, CaseIterable, Identifiable {
    case cerebro
    case simulator

    var id: Self { self }

    var label: String {
        switch self {
        case .cerebro: "Cerebro"
        case .simulator: "Simulator"
        }
    }
}

private enum RobotControlDomain {
    case drive
    case amberArm
}

private enum ArmMotionInput: Equatable {
    case screen
    case pairedControllers
}

private struct ArmOperatorWorkflowState {
    var selectedJoint = 0
    var draftPositions: [Double] = []
    var draftBaselineSequence: UInt64?
    var statusMessage = "Connect to Cerebro for supervised arm control"
}

private struct GripperSubmissionTracking {
    var messageID: UUID?
    let startedAtUptime: TimeInterval
    var observedPending = false
}

@MainActor
@Observable
final class RobotViewModel {
    private(set) var snapshot = RobotSessionSnapshot()
    private(set) var statusMessage = "Ready to connect to the simulator"
    private(set) var pairedCredential: ROBCerebroCredential?
    private(set) var pairingStatusMessage = "Install a unique pairing code issued by Cerebro."
    private(set) var videoActionIsPending = false
    var pairingCodeDraft = ""
    var showsPairingSheet = false
    var connectionDestination: RobotConnectionDestination = .simulator
    var speedLimit: Float = 0.65
    var operatorTextDraft = ""
    var operatorTextMode: OperatorTextMode = .command
    var showsArmControlSheet = false
    var selectedArm: RobotArmSide = .left
    var leftGripperForce = 5
    var rightGripperForce = 5
    private var leftArmWorkflow = ArmOperatorWorkflowState()
    private var rightArmWorkflow = ArmOperatorWorkflowState()
    private(set) var gripperControlStatusMessage =
        "Calibrate each gripper in Cerebro after power-up"
    private(set) var robotActionStatusMessage = "Action approvals are off"

    let gameController: GameControllerInput
    let headOrientation: HeadOrientationInput
    let videoPipeline: VideoPipelineCoordinator
    let speechInput: VisionSpeechInput

    @ObservationIgnored private let session: RobotSession
    @ObservationIgnored private let simulator: SimulatedRobotEndpoint
    @ObservationIgnored private let pairingStore: ROBCerebroPairingStore
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var actionID: UUID?
    @ObservationIgnored private var videoActionTask: Task<Void, Never>?
    @ObservationIgnored private var videoActionID: UUID?
    @ObservationIgnored private var virtualInputTask: Task<Void, Never>?
    @ObservationIgnored private var videoLifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var activeVideoDescriptor: VideoStreamDescriptor?
    @ObservationIgnored private var sceneIsActive = false
    @ObservationIgnored private var inputSequence: UInt64 = 0
    @ObservationIgnored private var latestGameControllerSample = GameControllerSample.disconnected
    @ObservationIgnored private var latestGameControllerSampleAtUptime: TimeInterval?
    @ObservationIgnored private var latestHeadOrientation = HeadOrientationSample.unavailable
    @ObservationIgnored private var activeControlDomain = RobotControlDomain.drive
    @ObservationIgnored private var armMotionTasks: [RobotArmSide: Task<Void, Never>] = [:]
    @ObservationIgnored private var armDeadManHeld: Set<RobotArmSide> = []
    @ObservationIgnored private var armMotionInputs: [RobotArmSide: ArmMotionInput] = [:]
    @ObservationIgnored private var lastHandledArmDispositionIDs: [RobotArmSide: UUID] = [:]
    @ObservationIgnored private var pairedControllerGripGestureWasHeld = false
    @ObservationIgnored private var pairedControllerControlIsActive = false
    @ObservationIgnored private var pairedReleaseHoldMessageIDs: [RobotArmSide: UUID] = [:]
    @ObservationIgnored private var pairedReleaseHoldAwaitingArms: Set<RobotArmSide> = []
    @ObservationIgnored private var gripperDeadManWasHeld = false
    @ObservationIgnored private var lastLeftGripperTrigger: Bool?
    @ObservationIgnored private var lastRightGripperTrigger: Bool?
    @ObservationIgnored private var gripperSubmissions: [RobotArmSide: GripperSubmissionTracking] = [:]
    @ObservationIgnored private var deferredGripperReleaseDeadlines: [RobotArmSide: TimeInterval] = [:]
    @ObservationIgnored private var gripperInputGeneration: UInt64 = 0

    var selectedArmJoint: Int {
        get { armWorkflow(for: selectedArm).selectedJoint }
        set {
            updateArmWorkflow(for: selectedArm) { workflow in
                workflow.selectedJoint = min(
                    RobotArmTargetIntent.jointCount - 1,
                    max(0, newValue)
                )
            }
        }
    }

    private(set) var armDraftPositions: [Double] {
        get { armWorkflow(for: selectedArm).draftPositions }
        set {
            updateArmWorkflow(for: selectedArm) { workflow in
                workflow.draftPositions = newValue
            }
        }
    }

    private var armDraftBaselineSequence: UInt64? {
        get { armWorkflow(for: selectedArm).draftBaselineSequence }
        set {
            updateArmWorkflow(for: selectedArm) { workflow in
                workflow.draftBaselineSequence = newValue
            }
        }
    }

    private(set) var armControlStatusMessage: String {
        get { armWorkflow(for: selectedArm).statusMessage }
        set { setArmControlStatusMessage(newValue, for: selectedArm) }
    }

    private func armWorkflow(for arm: RobotArmSide) -> ArmOperatorWorkflowState {
        switch arm {
        case .left:
            leftArmWorkflow
        case .right:
            rightArmWorkflow
        }
    }

    private func updateArmWorkflow(
        for arm: RobotArmSide,
        _ update: (inout ArmOperatorWorkflowState) -> Void
    ) {
        switch arm {
        case .left:
            update(&leftArmWorkflow)
        case .right:
            update(&rightArmWorkflow)
        }
    }

    private func setArmControlStatusMessage(_ message: String, for arm: RobotArmSide) {
        updateArmWorkflow(for: arm) { workflow in
            workflow.statusMessage = message
        }
    }

    init(
        session: RobotSession = RobotSession(),
        simulator: SimulatedRobotEndpoint? = nil,
        videoPipeline: VideoPipelineCoordinator = VideoPipelineCoordinator(),
        pairingStore: ROBCerebroPairingStore = ROBCerebroPairingStore()
    ) {
        self.session = session
        self.simulator =
            simulator
            ?? SimulatedRobotEndpoint(videoDataSource: SyntheticVideoDataSource())
        self.videoPipeline = videoPipeline
        self.speechInput = VisionSpeechInput()
        self.pairingStore = pairingStore
        self.gameController = GameControllerInput()
        self.headOrientation = HeadOrientationInput()
        self.speechInput.onTranscript = { [weak self] transcript, isFinal in
            guard let self else { return }
            self.operatorTextDraft = transcript
            if isFinal {
                self.sendOperatorText(as: self.operatorTextMode)
            }
        }
        self.gameController.onSample = { [weak self] sample in
            self?.acceptGameController(sample)
        }
        self.headOrientation.onSample = { [weak self] sample in
            self?.acceptHeadOrientation(sample)
        }
        reloadPairingStatus(selectCerebroWhenPaired: true)
    }

    deinit {
        updatesTask?.cancel()
        actionTask?.cancel()
        videoActionTask?.cancel()
        virtualInputTask?.cancel()
        videoLifecycleTask?.cancel()
        for task in armMotionTasks.values {
            task.cancel()
        }
    }

    func start() {
        guard updatesTask == nil else { return }
        gameController.start()
        headOrientation.start()
        let session = session
        updatesTask = Task { [weak self] in
            let updates = await session.updates()
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                self?.snapshot = snapshot
                self?.refreshStatusMessage(from: snapshot)
            }
        }

        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--video-smoke-test") {
                startVideoSmokeTest()
            }
        #endif
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        actionID = nil
        actionTask?.cancel()
        actionTask = nil
        cancelVideoAction()
        endVirtualMotion()
        cancelArmMotionLocally()
        clearGripperInputTracking()
        stopVideoPipeline()
        gameController.stop()
        headOrientation.stop()
        speechInput.stop()
        let session = session
        Task {
            await session.disconnect()
        }
    }

    func toggleConnection() {
        if snapshot.connection.phase == .connected
            || snapshot.connection.phase == .connecting
            || snapshot.connection.phase == .handshaking
        {
            disconnect()
        } else {
            switch connectionDestination {
            case .cerebro:
                connectToCerebro()
            case .simulator:
                connectToSimulator()
            }
        }
    }

    var hasInstalledCerebroCredential: Bool { pairedCredential != nil }

    var cerebroCredentialIsVerified: Bool {
        snapshot.connection.isReady
            && snapshot.connection.endpoint?.serviceType
                == ROBCerebroPairingStore.controlServiceType
    }

    var cerebroCredentialStatusLabel: String {
        if cerebroCredentialIsVerified {
            return "Connected and verified"
        }
        return hasInstalledCerebroCredential ? "Credential installed" : "No credential"
    }

    var pairedCerebroDescription: String? {
        guard let pairedCredential else { return nil }
        let name = pairedCredential.deviceName ?? "Apple Vision Pro"
        return "\(name) • \(pairedCredential.robotID.uuidString.prefix(8))"
    }

    var canChangeConnectionDestination: Bool {
        snapshot.connection.phase == .disconnected || snapshot.connection.phase == .failed
    }

    var canToggleConnection: Bool {
        switch snapshot.connection.phase {
        case .disconnecting:
            false
        case .connected, .connecting, .handshaking:
            true
        case .disconnected, .failed:
            connectionDestination == .simulator || hasInstalledCerebroCredential
        }
    }

    var connectionButtonTitle: String {
        switch snapshot.connection.phase {
        case .connected, .connecting, .handshaking:
            "Disconnect"
        case .disconnecting:
            "Disconnecting…"
        case .disconnected, .failed:
            connectionDestination == .cerebro ? "Connect Cerebro" : "Connect Simulator"
        }
    }

    func installPairingCode() {
        guard canChangeConnectionDestination else {
            pairingStatusMessage = "Disconnect before replacing the installed credential."
            return
        }
        do {
            pairedCredential = try pairingStore.install(pairingCode: pairingCodeDraft)
            pairingCodeDraft = ""
            connectionDestination = .cerebro
            pairingStatusMessage =
                "Pairing installed in this Vision Pro's Keychain. Connect to verify the certificate pin and reciprocal proof."
            statusMessage = "Ready to connect securely to Cerebro"
        } catch {
            pairingStatusMessage = error.localizedDescription
        }
    }

    func forgetPairing() {
        guard canChangeConnectionDestination else {
            pairingStatusMessage = "Disconnect before removing the installed credential."
            return
        }
        do {
            try pairingStore.removeCredential()
            pairedCredential = nil
            pairingCodeDraft = ""
            connectionDestination = .simulator
            pairingStatusMessage =
                "The local credential was removed. Revoke it in Cerebro if it should no longer be trusted."
            statusMessage = "Ready to connect to the simulator"
        } catch {
            pairingStatusMessage = error.localizedDescription
        }
    }

    func clearPairingCodeDraft() {
        pairingCodeDraft = ""
    }

    private func reloadPairingStatus(selectCerebroWhenPaired: Bool) {
        do {
            pairedCredential = try pairingStore.loadCredential()
            if let pairedCredential {
                if selectCerebroWhenPaired {
                    connectionDestination = .cerebro
                    statusMessage = "Ready to connect securely to Cerebro"
                }
                pairingStatusMessage =
                    "Credential ready for robot \(pairedCredential.robotID.uuidString.lowercased())."
            }
        } catch {
            pairedCredential = nil
            pairingStatusMessage = error.localizedDescription
        }
    }

    func connectToCerebro() {
        guard actionTask == nil else { return }
        do {
            guard let credential = try pairingStore.loadCredential() else {
                throw ROBCerebroTransportError.pairingRequired
            }
            pairedCredential = credential
            let transport = CerebroRobotTransport(credential: credential)
            statusMessage = "Discovering paired Cerebro services…"
            let session = session
            let id = UUID()
            actionID = id
            actionTask = Task { [weak self] in
                await session.configureRobotActionController(
                    senderID: credential.controllerID.uuidString.lowercased()
                )
                await session.connect(using: transport)
                self?.finishAction(id)
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func connectToSimulator() {
        guard actionTask == nil else { return }
        statusMessage = "Connecting to ROB Simulator…"
        let session = session
        let simulator = simulator
        let id = UUID()
        actionID = id
        actionTask = Task { [weak self] in
            await session.configureRobotActionController(senderID: nil)
            await session.connect(using: simulator)
            self?.finishAction(id)
        }
    }

    func disconnect() {
        endVirtualMotion()
        cancelArmMotionLocally()
        clearGripperInputTracking()
        stopVideoPipeline()
        cancelVideoAction()
        actionTask?.cancel()
        let session = session
        let id = UUID()
        actionID = id
        actionTask = Task { [weak self] in
            await session.disconnect()
            self?.finishAction(id)
        }
    }

    func toggleArmed() {
        let shouldArm = !snapshot.safety.isArmed
        if shouldArm && hasAnyActiveArmControl {
            statusMessage = "Disable Amber arm control before enabling drive control"
            return
        }
        if !shouldArm {
            endVirtualMotion()
            cancelArmMotionLocally()
        }
        let session = session
        Task {
            await session.setArmed(shouldArm)
        }
    }

    func emergencyStop() {
        endVirtualMotion()
        cancelArmMotionLocally()
        clearGripperInputTracking()
        let session = session
        Task {
            await session.emergencyStop()
        }
    }

    func resetEmergencyStop() {
        let session = session
        Task {
            await session.resetEmergencyStop()
        }
    }

    var pendingRobotAction: RobotActionMessage? {
        snapshot.robotActions.pendingRequest
    }

    var robotActionApprovalsAreEnabled: Bool {
        snapshot.robotActions.isEnabled
    }

    var pendingRobotActionIsExecuting: Bool {
        guard let request = pendingRobotAction,
              let status = snapshot.robotActions.lastStatus,
              status.callID == request.callID else { return false }
        return status.state == .accepted || status.state == .executing
    }

    var canEnableRobotActionApprovals: Bool {
        cerebroCredentialIsVerified
            && sceneIsActive
            && !snapshot.safety.emergencyStopIsLatched
    }

    func toggleRobotActionApprovals() {
        let shouldEnable = !robotActionApprovalsAreEnabled
        guard !shouldEnable || canEnableRobotActionApprovals else {
            robotActionStatusMessage =
                "Connect securely to Cerebro and release the software stop first"
            return
        }
        let session = session
        Task { [weak self] in
            do {
                try await session.setRobotActionApprovalsEnabled(shouldEnable)
                self?.robotActionStatusMessage = shouldEnable
                    ? "Cerebro may now propose bounded actions for explicit approval"
                    : "Action approvals are off"
            } catch {
                self?.robotActionStatusMessage = error.localizedDescription
            }
        }
    }

    func approvePendingRobotAction() {
        respondToPendingRobotAction(
            .accepted,
            detail: "Vision operator approved while physically supervising beside the droid."
        )
    }

    func rejectPendingRobotAction() {
        respondToPendingRobotAction(
            .rejected,
            detail: "Vision operator rejected the proposed action."
        )
    }

    func cancelPendingRobotAction() {
        respondToPendingRobotAction(
            .cancelled,
            detail: "Vision operator requested that the accepted action stop and hold safely."
        )
    }

    func confirmPendingRobotActionCompleted() {
        respondToPendingRobotAction(
            .completed,
            detail: "Vision operator confirmed that the supervised manual action completed."
        )
    }

    func reportPendingRobotActionFailed() {
        respondToPendingRobotAction(
            .failed,
            detail: "Vision operator reported that the supervised manual action failed."
        )
    }

    private func respondToPendingRobotAction(
        _ state: RobotActionState,
        detail: String
    ) {
        let session = session
        let action = snapshot.robotActions.pendingRequest?.action
        Task { [weak self] in
            do {
                try await session.respondToPendingRobotAction(state, detail: detail)
                if state == .accepted, action == .playGesture {
                    self?.robotActionStatusMessage =
                        "Approved — Cerebro owns gesture execution and measured completion"
                } else if state == .accepted {
                    self?.robotActionStatusMessage =
                        "Approved — supervise the action, then report completion or failure"
                } else {
                    self?.robotActionStatusMessage = "Action reported as \(state.rawValue)"
                }
            } catch {
                self?.robotActionStatusMessage = error.localizedDescription
            }
        }
    }

    var supportsPhysicalArmControl: Bool {
        snapshot.connection.isReady
            && snapshot.connection.handshake?.capabilities.supportsArmControlExecution == true
            && snapshot.connection.endpoint?.transport == .quic
    }

    func armMeasuredState(for arm: RobotArmSide) -> RobotArmMeasuredState? {
        snapshot.armTelemetry.measuredState(for: arm)
    }

    func armControlState(for arm: RobotArmSide) -> RobotArmControlSnapshot {
        snapshot.armTelemetry.controlState(for: arm)
    }

    func armDraftPositions(for arm: RobotArmSide) -> [Double] {
        armWorkflow(for: arm).draftPositions
    }

    func selectedArmJoint(for arm: RobotArmSide) -> Int {
        armWorkflow(for: arm).selectedJoint
    }

    func setSelectedArmJoint(_ joint: Int, for arm: RobotArmSide) {
        guard !armDeadManControlIsActive(for: arm) else { return }
        updateArmWorkflow(for: arm) { workflow in
            workflow.selectedJoint = min(RobotArmTargetIntent.jointCount - 1, max(0, joint))
        }
    }

    func armControlStatusMessage(for arm: RobotArmSide) -> String {
        armWorkflow(for: arm).statusMessage
    }

    var selectedArmMeasuredState: RobotArmMeasuredState? {
        armMeasuredState(for: selectedArm)
    }

    var selectedArmControlState: RobotArmControlSnapshot {
        armControlState(for: selectedArm)
    }

    var selectedGripperState: RobotGripperState? {
        snapshot.gripperTelemetry.state(for: selectedArm)
    }

    var selectedGripperControlState: RobotGripperControlSnapshot {
        snapshot.gripperTelemetry.control(for: selectedArm)
    }

    var selectedGripperForce: Int {
        get { selectedArm == .left ? leftGripperForce : rightGripperForce }
        set {
            let bounded = min(
                RobotGripperCommandIntent.forceRange.upperBound,
                max(RobotGripperCommandIntent.forceRange.lowerBound, newValue)
            )
            if selectedArm == .left { leftGripperForce = bounded }
            else { rightGripperForce = bounded }
        }
    }

    var selectedGripperCanOperate: Bool {
        snapshot.connection.isReady
            && sceneIsActive
            && !snapshot.safety.emergencyStopIsLatched
            && pairedSpatialDeadManIsHeld
            && gripperDeadManInputIsFresh()
            && selectedGripperState?.calibrationState == .commandAcceptedUnverified
            && selectedGripperControlState.pendingCommandMessageID == nil
    }

    func operateSelectedGripper(_ action: RobotGripperAction) {
        submitGripper(
            arm: selectedArm,
            action: action,
            deadManIsHeld: pairedSpatialDeadManIsHeld
        )
    }

    var selectedArmTelemetryAgeMilliseconds: Double? {
        armTelemetryAgeMilliseconds(for: selectedArm)
    }

    func armTelemetryAgeMilliseconds(for arm: RobotArmSide) -> Double? {
        snapshot.armTelemetry.effectiveSampleAgeMilliseconds(for: arm)
    }

    var selectedArmTelemetryIsFresh: Bool {
        armTelemetryIsFresh(for: selectedArm)
    }

    func armTelemetryIsFresh(for arm: RobotArmSide) -> Bool {
        guard let age = armTelemetryAgeMilliseconds(for: arm) else { return false }
        return age.isFinite && (0 ... 250).contains(age)
    }

    var selectedArmModesArePosition: Bool {
        armModesArePosition(for: selectedArm)
    }

    func armModesArePosition(for arm: RobotArmSide) -> Bool {
        guard let modes = armMeasuredState(for: arm)?.modes else { return false }
        return modes.count == RobotArmTargetIntent.jointCount && modes.allSatisfy { $0 == 2 }
    }

    var selectedArmAuthorityIsGranted: Bool {
        armAuthorityIsGranted(for: selectedArm)
    }

    func armAuthorityIsGranted(for arm: RobotArmSide) -> Bool {
        let control = armControlState(for: arm)
        return control.localControlIsArmed && control.authorityID != nil
    }

    var selectedArmHasServerAuthority: Bool {
        armHasServerAuthority(selectedArm)
    }

    func armHasServerAuthority(_ arm: RobotArmSide) -> Bool {
        armControlState(for: arm).authorityState?.state == .granted
    }

    var selectedArmAuthorityIsPending: Bool {
        armAuthorityIsPending(selectedArm)
    }

    func armAuthorityIsPending(_ arm: RobotArmSide) -> Bool {
        armControlState(for: arm).pendingAuthorityRequestID != nil
    }

    var armDeadManControlIsActive: Bool {
        armDeadManControlIsActive(for: selectedArm)
    }

    func armDeadManControlIsActive(for arm: RobotArmSide) -> Bool {
        armDeadManHeld.contains(arm) || armMotionTasks[arm] != nil
    }

    var hasAnyActiveArmControl: Bool {
        RobotArmSide.allCases.contains { arm in
            let control = armControlState(for: arm)
            return control.localControlIsArmed
                || control.authorityID != nil
                || control.pendingAuthorityRequestID != nil
                || armMotionTasks[arm] != nil
        }
    }

    var pairedSpatialControllersAreConnected: Bool {
        gameController.leftSpatialControllerIsConnected
            && gameController.rightSpatialControllerIsConnected
    }

    var pairedSpatialDeadManIsHeld: Bool {
        pairedSpatialControllersAreConnected
            && gameController.leftSpatialGripIsHeld
            && gameController.rightSpatialGripIsHeld
    }

    var pairedControllerJogIsActive: Bool {
        pairedControllerControlIsActive
    }

    var canInitializeArmDraft: Bool {
        canInitializeArmDraft(for: selectedArm)
    }

    func canInitializeArmDraft(for arm: RobotArmSide) -> Bool {
        armTelemetryIsFresh(for: arm)
            || armControlState(for: arm).authorityState?.baselinePositionsRadians.count
                == RobotArmTargetIntent.jointCount
    }

    var canBeginArmMotion: Bool {
        canBeginArmMotion(for: selectedArm)
    }

    func canBeginArmMotion(for arm: RobotArmSide) -> Bool {
        supportsPhysicalArmControl
            && sceneIsActive
            && armAuthorityIsGranted(for: arm)
            && armTelemetryIsFresh(for: arm)
            && armModesArePosition(for: arm)
            && armDraftPositions(for: arm).count == RobotArmTargetIntent.jointCount
            && armControlState(for: arm).activeTargetMessageID == nil
            && armControlState(for: arm).pendingHoldMessageID == nil
            && !snapshot.safety.emergencyStopIsLatched
    }

    func initializeArmDraft() {
        initializeArmDraft(for: selectedArm)
    }

    func initializeArmDraft(for arm: RobotArmSide) {
        let control = armControlState(for: arm)
        if let authority = control.authorityState,
            authority.state == .granted,
            authority.baselinePositionsRadians.count == RobotArmTargetIntent.jointCount
        {
            updateArmWorkflow(for: arm) { workflow in
                workflow.draftPositions = authority.baselinePositionsRadians
                workflow.draftBaselineSequence = authority.baselineSequence
                workflow.statusMessage = "Draft initialized from Cerebro's captured hold baseline"
            }
            return
        }
        guard armTelemetryIsFresh(for: arm), let measured = armMeasuredState(for: arm) else {
            setArmControlStatusMessage(
                "Fresh measured feedback (250 ms or newer) is required",
                for: arm
            )
            return
        }
        updateArmWorkflow(for: arm) { workflow in
            workflow.draftPositions = measured.positionsRadians
            workflow.draftBaselineSequence = measured.sequence
            workflow.statusMessage = "Draft initialized from measured pose #\(measured.sequence)"
        }
    }

    func armDraftBounds(for joint: Int) -> ClosedRange<Double> {
        armDraftBounds(for: selectedArm, joint: joint)
    }

    func armDraftBounds(for arm: RobotArmSide, joint: Int) -> ClosedRange<Double> {
        guard RobotArmTargetIntent.jointBoundsRadians.indices.contains(joint) else { return 0 ... 0 }
        let hard = RobotArmTargetIntent.jointBoundsRadians[joint]
        let measuredPositions = armMeasuredState(for: arm)?.positionsRadians ?? []
        let baselinePositions = armControlState(for: arm).authorityState?
            .baselinePositionsRadians ?? []
        let measuredCenter = measuredPositions.indices.contains(joint)
            ? measuredPositions[joint] : nil
        let baselineCenter = baselinePositions.indices.contains(joint)
            ? baselinePositions[joint] : nil
        guard let rawCenter = measuredCenter ?? baselineCenter else { return 0 ... 0 }
        let center = min(hard.upperBound, max(hard.lowerBound, rawCenter))
        return max(hard.lowerBound, center - 0.08) ... min(hard.upperBound, center + 0.08)
    }

    func updateArmDraft(joint: Int, value: Double) {
        updateArmDraft(for: selectedArm, joint: joint, value: value)
    }

    func updateArmDraft(for arm: RobotArmSide, joint: Int, value: Double) {
        let workflow = armWorkflow(for: arm)
        guard workflow.draftPositions.indices.contains(joint), joint == workflow.selectedJoint else {
            return
        }
        let bounds = armDraftBounds(for: arm, joint: joint)
        updateArmWorkflow(for: arm) { workflow in
            workflow.draftPositions[joint] = min(bounds.upperBound, max(bounds.lowerBound, value))
        }
    }

    func toggleSelectedArmControl() {
        toggleArmControl(for: selectedArm)
    }

    func toggleArmControl(for arm: RobotArmSide) {
        if pairedControllerControlIsActive || !pairedReleaseHoldAwaitingArms.isEmpty {
            requestPriorityHoldBoth(reason: "authority_changed_during_paired_control")
            return
        }
        if armHasServerAuthority(arm) || armAuthorityIsPending(arm) {
            cancelArmMotionLocally(for: arm)
            let session = session
            Task { [weak self] in
                do {
                    try await session.releaseArmAuthority(for: arm)
                    self?.setArmControlStatusMessage(
                        "Arm control released; measured hold requested",
                        for: arm
                    )
                    self?.recomputeActiveControlDomain()
                } catch {
                    self?.setArmControlStatusMessage(error.localizedDescription, for: arm)
                }
            }
            return
        }
        guard supportsPhysicalArmControl else {
            setArmControlStatusMessage(
                "The selected endpoint does not support physical arm execution",
                for: arm
            )
            return
        }
        let session = session
        activeControlDomain = .amberArm
        setArmControlStatusMessage(
            "Requesting time-limited \(arm.rawValue) arm authority…",
            for: arm
        )
        Task { [weak self] in
            guard let self else { return }
            if self.snapshot.safety.isArmed {
                await session.setArmed(false)
            }
            do {
                _ = try await session.requestArmAuthority(for: arm)
                self.setArmControlStatusMessage(
                    "Waiting for Cerebro authority and measured baseline…",
                    for: arm
                )
            } catch {
                self.setArmControlStatusMessage(error.localizedDescription, for: arm)
                self.recomputeActiveControlDomain()
            }
        }
    }

    func beginArmMotion() {
        beginArmMotion(for: selectedArm)
    }

    func beginArmMotion(for arm: RobotArmSide) {
        beginArmMotion(for: arm, input: .screen)
    }

    private func beginArmMotion(for arm: RobotArmSide, input: ArmMotionInput) {
        guard armMotionTasks[arm] == nil, canBeginArmMotion(for: arm) else {
            setArmControlStatusMessage("Arm preflight is incomplete", for: arm)
            return
        }
        armDeadManHeld.insert(arm)
        armMotionInputs[arm] = input
        activeControlDomain = .amberArm
        let session = session
        armMotionTasks[arm] = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            // A deliberate dwell makes an accidental tap non-operative.
            do { try await clock.sleep(for: .milliseconds(350)) } catch { return }
            while !Task.isCancelled {
                guard let self, self.armDeadManHeld.contains(arm) else { return }
                if input == .pairedControllers, !self.pairedControllerInputIsFreshAndHeld {
                    self.failPairedControllerMotion(reason: "paired_controller_input_expired")
                    return
                }
                guard self.canContinueArmMotion(for: arm) else {
                    self.setArmControlStatusMessage(
                        "Arm preflight changed; requesting measured hold",
                        for: arm
                    )
                    if input == .pairedControllers {
                        self.failPairedControllerMotion(reason: "paired_arm_preflight_changed")
                    } else {
                        self.endArmMotion(for: arm, reason: "arm_preflight_changed")
                    }
                    return
                }
                let control = self.snapshot.armTelemetry.controlState(for: arm)
                if let sentAt = control.activeTargetSentAtUptime,
                    ProcessInfo.processInfo.systemUptime - sentAt > 1.2
                {
                    self.setArmControlStatusMessage(
                        "Target response timed out; requesting measured hold",
                        for: arm
                    )
                    if input == .pairedControllers {
                        self.failPairedControllerMotion(reason: "paired_target_response_timeout")
                    } else {
                        self.endArmMotion(for: arm, reason: "target_response_timeout")
                    }
                    return
                }
                if control.activeTargetMessageID == nil {
                    switch self.nextArmTargetSegment(for: arm, input: input) {
                    case .target(let target):
                        do {
                            _ = try await session.submitArmTargetSegment(target)
                            self.setArmControlStatusMessage(
                                "Segment sent; waiting for measured completion",
                                for: arm
                            )
                        } catch {
                            self.setArmControlStatusMessage(error.localizedDescription, for: arm)
                            if input == .pairedControllers {
                                self.failPairedControllerMotion(reason: "paired_target_send_failed")
                            } else {
                                self.endArmMotion(for: arm, reason: "target_send_failed")
                            }
                            return
                        }
                    case .idle:
                        self.setArmControlStatusMessage(
                            input == .pairedControllers
                                ? "Controller stick centered; dual dead-man remains held"
                                : "Draft reached; release to confirm measured hold",
                            for: arm
                        )
                    case .inhibited(let detail):
                        self.setArmControlStatusMessage(
                            "Controller jog inhibited: \(detail)",
                            for: arm
                        )
                        self.failPairedControllerMotion(reason: "paired_jog_mapper_inhibited")
                        return
                    }
                }
                do { try await clock.sleep(for: .milliseconds(80)) } catch { return }
            }
        }
    }

    func endArmMotion(reason: String = "operator_released_dead_man") {
        endArmMotion(for: selectedArm, reason: reason)
    }

    func endArmMotion(
        for arm: RobotArmSide,
        reason: String = "operator_released_dead_man"
    ) {
        let wasActive = armDeadManHeld.contains(arm) || armMotionTasks[arm] != nil
        cancelArmMotionLocally(for: arm)
        guard wasActive, snapshot.connection.isReady else { return }
        let session = session
        Task { [weak self] in
            do {
                _ = try await session.requestArmHold(for: arm, reason: reason)
                self?.setArmControlStatusMessage("Measured-position hold requested", for: arm)
            } catch {
                self?.setArmControlStatusMessage(
                    "Hold request failed: \(error.localizedDescription)",
                    for: arm
                )
            }
        }
    }

    private func endPairedControllerMotionPreservingAuthority(reason: String) {
        guard pairedControllerControlIsActive || armMotionInputs.values.contains(.pairedControllers)
        else { return }
        pairedControllerControlIsActive = false
        cancelArmMotionLocally()
        guard snapshot.connection.isReady else { return }
        pairedReleaseHoldMessageIDs.removeAll()
        pairedReleaseHoldAwaitingArms = Set(RobotArmSide.allCases)
        let session = session
        Task { [weak self] in
            for arm in RobotArmSide.allCases {
                do {
                    let messageID = try await session.requestArmHold(for: arm, reason: reason)
                    self?.pairedReleaseHoldMessageIDs[arm] = messageID
                    self?.setArmControlStatusMessage(
                        "Controller dead-man released; awaiting measured hold confirmation",
                        for: arm
                    )
                    if let disposition = self?.armControlState(for: arm).lastDisposition {
                        self?.reconcilePairedReleaseHold(for: arm, disposition: disposition)
                    }
                } catch {
                    self?.setArmControlStatusMessage(
                        "Hold request failed: \(error.localizedDescription)",
                        for: arm
                    )
                    self?.requestPriorityHoldBoth(reason: "paired_release_hold_send_failed")
                    return
                }
            }
        }
    }

    func requestPriorityHoldBoth() {
        requestPriorityHoldBoth(reason: "operator_priority_hold_both")
    }

    private func requestPriorityHoldBoth(reason: String) {
        cancelArmMotionLocally()
        pairedControllerControlIsActive = false
        pairedReleaseHoldMessageIDs.removeAll()
        pairedReleaseHoldAwaitingArms.removeAll()
        let session = session
        Task { [weak self] in
            await session.requestPriorityArmHolds(reason: reason)
            for arm in RobotArmSide.allCases {
                self?.setArmControlStatusMessage(
                    "Priority measured holds requested for both arms",
                    for: arm
                )
            }
            self?.recomputeActiveControlDomain()
        }
    }

    func armControlPanelDidDisappear() {
        if pairedControllerControlIsActive {
            endPairedControllerMotionPreservingAuthority(reason: "arm_control_sheet_closed")
        } else {
            for arm in RobotArmSide.allCases where armMotionTasks[arm] != nil {
                endArmMotion(for: arm, reason: "arm_control_sheet_closed")
            }
        }
        pairedControllerGripGestureWasHeld = pairedSpatialDeadManIsHeld
    }

    private func canContinueArmMotion(for arm: RobotArmSide) -> Bool {
        let measured = snapshot.armTelemetry.measuredState(for: arm)
        let control = snapshot.armTelemetry.controlState(for: arm)
        let telemetryAge = snapshot.armTelemetry.effectiveSampleAgeMilliseconds(for: arm)
        return supportsPhysicalArmControl
            && sceneIsActive
            && control.localControlIsArmed
            && control.authorityID != nil
            && telemetryAge.map { $0.isFinite && (0 ... 250).contains($0) } == true
            && measured?.modes.count == RobotArmTargetIntent.jointCount
            && measured?.modes.allSatisfy { $0 == 2 } == true
            && !snapshot.safety.emergencyStopIsLatched
    }

    private enum NextArmTarget {
        case target(RobotArmTargetIntent)
        case idle
        case inhibited(String)
    }

    private func nextArmTargetSegment(
        for arm: RobotArmSide,
        input: ArmMotionInput
    ) -> NextArmTarget {
        if input == .pairedControllers {
            guard let configuration = RobotDualArmJointJogMapper.Configuration(
                leftJointIndex: selectedArmJoint(for: .left),
                rightJointIndex: selectedArmJoint(for: .right)
            ) else { return .inhibited("invalid selected joint") }
            switch RobotDualArmJointJogMapper(configuration: configuration).map(
                leftStickY: Double(latestGameControllerSample.leftPrimaryStickY),
                rightStickY: Double(latestGameControllerSample.rightPrimaryStickY),
                leftMeasuredState: armMeasuredState(for: .left),
                rightMeasuredState: armMeasuredState(for: .right),
                leftEffectiveSampleAgeMilliseconds: armTelemetryAgeMilliseconds(for: .left),
                rightEffectiveSampleAgeMilliseconds: armTelemetryAgeMilliseconds(for: .right)
            ) {
            case .targets(let left, let right):
                let target = arm == .left ? left : right
                return target.map(NextArmTarget.target) ?? .idle
            case .inhibited(let reason):
                return .inhibited(String(describing: reason))
            }
        }

        let workflow = armWorkflow(for: arm)
        guard let measured = snapshot.armTelemetry.measuredState(for: arm),
            workflow.draftPositions.indices.contains(workflow.selectedJoint),
            measured.positionsRadians.indices.contains(workflow.selectedJoint)
        else { return .idle }
        let desired = workflow.draftPositions[workflow.selectedJoint]
        let current = measured.positionsRadians[workflow.selectedJoint]
        let remaining = desired - current
        guard abs(remaining) > 0.005 else { return .idle }
        var segment = measured.positionsRadians
        segment[workflow.selectedJoint] = current + min(0.08, max(-0.08, remaining))
        guard let target = RobotArmTargetIntent(
            arm: arm,
            source: .visionProJointUI,
            positionsRadians: segment,
            durationSeconds: 0.65
        ) else { return .inhibited("target exceeded protocol bounds") }
        return .target(target)
    }

    private func cancelArmMotionLocally(for arm: RobotArmSide? = nil) {
        if let arm {
            armDeadManHeld.remove(arm)
            armMotionInputs.removeValue(forKey: arm)
            armMotionTasks.removeValue(forKey: arm)?.cancel()
            return
        }
        armDeadManHeld.removeAll()
        armMotionInputs.removeAll()
        pairedControllerControlIsActive = false
        pairedReleaseHoldMessageIDs.removeAll()
        pairedReleaseHoldAwaitingArms.removeAll()
        let tasks = Array(armMotionTasks.values)
        armMotionTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    private var pairedControllerInputIsFreshAndHeld: Bool {
        guard pairedControllerControlIsActive,
            latestGameControllerSample.leftSpatialControllerIsConnected,
            latestGameControllerSample.rightSpatialControllerIsConnected,
            latestGameControllerSample.leftSpatialGripIsHeld,
            latestGameControllerSample.rightSpatialGripIsHeld,
            let receivedAt = latestGameControllerSampleAtUptime
        else { return false }
        return ProcessInfo.processInfo.systemUptime - receivedAt <= 0.25
    }

    private func synchronizePairedControllerArmInput(from sample: GameControllerSample) {
        let bothConnected = sample.leftSpatialControllerIsConnected
            && sample.rightSpatialControllerIsConnected
        let bothGripsHeld = bothConnected
            && sample.leftSpatialGripIsHeld
            && sample.rightSpatialGripIsHeld

        guard bothConnected else {
            pairedControllerGripGestureWasHeld = false
            if pairedControllerControlIsActive {
                failPairedControllerMotion(reason: "paired_controller_disconnected")
            }
            return
        }
        guard bothGripsHeld else {
            pairedControllerGripGestureWasHeld = false
            if pairedControllerControlIsActive {
                endPairedControllerMotionPreservingAuthority(
                    reason: "paired_controller_dead_man_released"
                )
            }
            return
        }

        // Require a new two-grip gesture after every failed preflight or stop;
        // an authority grant cannot turn an already-held gesture into motion.
        guard !pairedControllerGripGestureWasHeld else { return }
        pairedControllerGripGestureWasHeld = true
        guard showsArmControlSheet else { return }
        guard pairedReleaseHoldAwaitingArms.isEmpty else {
            for arm in RobotArmSide.allCases {
                setArmControlStatusMessage(
                    "Wait for both measured holds, then release and re-hold both grips",
                    for: arm
                )
            }
            return
        }
        guard armMotionTasks.isEmpty else {
            for arm in RobotArmSide.allCases {
                setArmControlStatusMessage(
                    "Release on-screen arm controls before paired controller jog",
                    for: arm
                )
            }
            return
        }
        guard RobotArmSide.allCases.allSatisfy({ canBeginArmMotion(for: $0) }) else {
            for arm in RobotArmSide.allCases {
                setArmControlStatusMessage(
                    "Both arms must pass preflight; release and re-hold both grips",
                    for: arm
                )
            }
            return
        }

        pairedControllerControlIsActive = true
        beginArmMotion(for: .left, input: .pairedControllers)
        beginArmMotion(for: .right, input: .pairedControllers)
    }

    private func failPairedControllerMotion(reason: String) {
        guard pairedControllerControlIsActive else { return }
        pairedControllerControlIsActive = false
        requestPriorityHoldBoth(reason: reason)
    }

    private func reconcilePairedReleaseHold(
        for arm: RobotArmSide,
        disposition: RobotArmTargetDisposition
    ) {
        guard pairedReleaseHoldAwaitingArms.contains(arm),
            pairedReleaseHoldMessageIDs[arm] == disposition.targetMessageID,
            disposition.terminal
        else { return }
        if disposition.disposition == .holdConfirmed {
            pairedReleaseHoldAwaitingArms.remove(arm)
            pairedReleaseHoldMessageIDs.removeValue(forKey: arm)
            if pairedReleaseHoldAwaitingArms.isEmpty {
                for side in RobotArmSide.allCases {
                    setArmControlStatusMessage(
                        "Both measured holds confirmed; release and re-hold both grips to jog",
                        for: side
                    )
                }
            }
        } else {
            requestPriorityHoldBoth(reason: "paired_release_hold_unconfirmed")
        }
    }

    private func recomputeActiveControlDomain() {
        activeControlDomain = hasAnyActiveArmControl ? .amberArm : .drive
    }

    func toggleVisionDictation() {
        speechInput.toggle()
    }

    func sendOperatorText() {
        let text = operatorTextDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusMessage = "Dictate or type something first"
            return
        }
        let mode = operatorTextMode
        let session = session
        Task { [weak self] in
            do {
                try await session.sendOperatorText(text, mode: mode)
                self?.statusMessage = mode == .command
                    ? "Vision Pro text sent as ROB input"
                    : "Puppet speech sent to ROB"
            } catch {
                self?.statusMessage = error.localizedDescription
            }
        }
    }

    func sendOperatorText(as mode: OperatorTextMode) {
        operatorTextMode = mode
        sendOperatorText()
    }

    func toggleVideoSubscription() {
        guard videoActionTask == nil else { return }
        let session = session
        let id = UUID()
        videoActionID = id
        videoActionIsPending = true
        if let activeStream = snapshot.videoStreams.first {
            videoActionTask = Task { [weak self] in
                do {
                    try await session.unsubscribeVideo(activeStream.id)
                    if !Task.isCancelled {
                        self?.statusMessage = "Video subscription stopped"
                    }
                } catch {
                    if !Task.isCancelled {
                        self?.statusMessage = error.localizedDescription
                    }
                }
                self?.finishVideoAction(id)
            }
            return
        }

        guard let camera = snapshot.connection.handshake?.capabilities.cameras.first else {
            statusMessage = "The connected robot did not advertise a camera"
            finishVideoAction(id)
            return
        }

        let delivery: VideoDeliveryMode =
            snapshot.connection.endpoint?.transport == .simulated
            ? .quicDatagrams
            : .reliableStream
        let request = Self.videoRequest(cameraID: camera.id, delivery: delivery)
        videoActionTask = Task { [weak self] in
            do {
                let response = try await session.subscribeVideo(request)
                switch response {
                case .accepted:
                    self?.statusMessage = "Video subscription negotiated"
                case .rejected(_, let reason):
                    self?.statusMessage = "Video subscription rejected: \(reason.rawValue)"
                }
            } catch {
                if !Task.isCancelled {
                    self?.statusMessage = error.localizedDescription
                }
            }
            self?.finishVideoAction(id)
        }
    }

    private static func videoRequest(
        cameraID: CameraID,
        delivery: VideoDeliveryMode
    ) -> VideoSubscriptionRequest {
        VideoSubscriptionRequest(
            cameraID: cameraID,
            preferredCodecs: [.h264],
            constraints: VideoConstraints(
                maximumWidth: 960,
                maximumHeight: 540,
                maximumFramesPerSecond: 20,
                maximumBitrate: 1_500_000
            ),
            delivery: delivery
        )
    }

    #if DEBUG
        private func startVideoSmokeTest() {
            guard actionTask == nil else { return }
            let session = session
            let simulator = simulator
            let id = UUID()
            actionID = id
            actionTask = Task { [weak self] in
                await session.connect(using: simulator)
                let snapshot = await session.currentSnapshot()
                guard let cameraID = snapshot.connection.handshake?.capabilities.cameras.first?.id else {
                    self?.statusMessage = "Video smoke test found no camera"
                    self?.finishAction(id)
                    return
                }
                do {
                    _ = try await session.subscribeVideo(
                        Self.videoRequest(cameraID: cameraID, delivery: .quicDatagrams)
                    )
                } catch {
                    self?.statusMessage = "Video smoke test failed: \(error.localizedDescription)"
                }
                self?.finishAction(id)
            }
        }
    #endif

    func beginVirtualMotion(linear: Float, angular: Float) {
        guard activeControlDomain == .drive,
            sceneIsActive,
            snapshot.connection.isReady,
            snapshot.safety.isArmed,
            !snapshot.safety.emergencyStopIsLatched
        else { return }

        virtualInputTask?.cancel()
        let limitedLinear = linear * speedLimit
        let limitedAngular = angular * speedLimit
        let session = session
        virtualInputTask = Task { [weak self] in
            let timer = ContinuousClock()
            while !Task.isCancelled {
                guard let self else { return }
                self.inputSequence &+= 1
                let sample = OperatorControlSample(
                    sequence: self.inputSequence,
                    source: .spatialUI,
                    linear: limitedLinear,
                    angular: limitedAngular,
                    deadManIsHeld: true
                )
                await session.updateOperatorInput(sample)
                do {
                    try await timer.sleep(for: .milliseconds(80))
                } catch {
                    return
                }
            }
        }
    }

    func endVirtualMotion() {
        virtualInputTask?.cancel()
        virtualInputTask = nil
        let session = session
        Task {
            await session.invalidateInput(reason: .deadManReleased)
        }
    }

    func setSceneActive(_ active: Bool) {
        sceneIsActive = active
        let activeVideoID = snapshot.videoStreams.first?.id
        if !active {
            clearPairingCodeDraft()
            cancelVideoAction()
            endVirtualMotion()
            cancelArmMotionLocally()
            clearGripperInputTracking()
            pairedControllerGripGestureWasHeld = false
            latestGameControllerSampleAtUptime = nil
            stopVideoPipeline()
        } else {
            synchronizeVideoPipeline(from: snapshot)
        }
        let session = session
        Task {
            await session.setSceneActive(active)
            if !active, let activeVideoID {
                try? await session.unsubscribeVideo(activeVideoID)
            }
        }
    }

    private func acceptGameController(_ sample: GameControllerSample) {
        guard sceneIsActive else { return }
        latestGameControllerSample = sample
        latestGameControllerSampleAtUptime = ProcessInfo.processInfo.systemUptime
        synchronizePairedControllerArmInput(from: sample)
        submitGripperTriggerEdges(from: sample)
        if activeControlDomain == .amberArm {
            headOrientation.setDeadManHeld(false)
            return
        }
        headOrientation.setDeadManHeld(sample.isConnected && sample.deadManIsHeld)
        guard sample.isConnected else {
            let session = session
            Task {
                await session.invalidateInput(reason: .controllerDisconnected)
            }
            return
        }

        sendCombinedControllerSample()
    }

    private func submitGripperTriggerEdges(from sample: GameControllerSample) {
        let deadManIsHeld = sample.leftSpatialControllerIsConnected
            && sample.rightSpatialControllerIsConnected
            && sample.leftSpatialGripIsHeld
            && sample.rightSpatialGripIsHeld
        defer { gripperDeadManWasHeld = deadManIsHeld }
        guard deadManIsHeld else {
            lastLeftGripperTrigger = nil
            lastRightGripperTrigger = nil
            if !deferredGripperReleaseDeadlines.isEmpty {
                deferredGripperReleaseDeadlines.removeAll()
                gripperControlStatusMessage =
                    "Queued gripper release cancelled when the two-grip dead-man was released; physical state unknown"
            }
            return
        }

        guard gripperDeadManWasHeld else {
            // Baseline both triggers on every dead-man acquisition. An index
            // trigger that was already held cannot become a synthetic press.
            lastLeftGripperTrigger = sample.leftGripperClosed
            lastRightGripperTrigger = sample.rightGripperClosed
            return
        }

        let edges: [(RobotArmSide, Bool, Bool?)] = [
            (.left, sample.leftGripperClosed, lastLeftGripperTrigger),
            (.right, sample.rightGripperClosed, lastRightGripperTrigger),
        ]
        lastLeftGripperTrigger = sample.leftGripperClosed
        lastRightGripperTrigger = sample.rightGripperClosed
        for (arm, isPressed, previous) in edges {
            if isPressed, previous != true {
                deferredGripperReleaseDeadlines.removeValue(forKey: arm)
                submitGripper(arm: arm, action: .hold, deadManIsHeld: true)
            } else if !isPressed, previous == true {
                submitGripper(arm: arm, action: .release, deadManIsHeld: true)
            }
        }
        reconcileGripperSubmissions(from: snapshot)
    }

    private func submitGripper(
        arm: RobotArmSide,
        action: RobotGripperAction,
        deadManIsHeld: Bool,
        isDeferredReleaseRetry: Bool = false
    ) {
        let force = arm == .left ? leftGripperForce : rightGripperForce
        guard let intent = RobotGripperCommandIntent(
            arm: arm,
            action: action,
            force: force
        ) else {
            gripperControlStatusMessage = "Gripper force must be 2 through 20 vendor units"
            return
        }
        guard deadManIsHeld, gripperDeadManInputIsFresh() else {
            gripperControlStatusMessage =
                "Fresh input with both controller grip buttons held is required"
            return
        }
        guard snapshot.gripperTelemetry.state(for: arm)?.calibrationState
                == .commandAcceptedUnverified else {
            gripperControlStatusMessage =
                "\(arm.rawValue.capitalized) gripper needs Cerebro calibration for this power session"
            return
        }
        if gripperSubmissions[arm] != nil
            || snapshot.gripperTelemetry.control(for: arm).pendingCommandMessageID != nil
        {
            if action == .release {
                deferredGripperReleaseDeadlines[arm] =
                    ProcessInfo.processInfo.systemUptime + 3.0
                gripperControlStatusMessage =
                    "\(arm.rawValue.capitalized) release queued briefly; keep both grips held"
            } else {
                gripperControlStatusMessage =
                    "\(arm.rawValue.capitalized) gripper is awaiting its previous acknowledgement"
            }
            return
        }

        let generation = gripperInputGeneration
        gripperSubmissions[arm] = GripperSubmissionTracking(
            messageID: nil,
            startedAtUptime: ProcessInfo.processInfo.systemUptime
        )
        let session = session
        Task { [weak self] in
            do {
                let messageID = try await session.submitGripperCommand(
                    intent,
                    deadManIsHeld: deadManIsHeld
                )
                guard let self,
                    self.gripperInputGeneration == generation,
                    var tracking = self.gripperSubmissions[arm]
                else { return }
                tracking.messageID = messageID
                self.gripperSubmissions[arm] = tracking
                self.gripperControlStatusMessage = isDeferredReleaseRetry
                    ? "Prior physical outcome remains unverified; \(arm.rawValue) release retry sent at intensity \(force), awaiting Amber acknowledgement"
                    : "\(arm.rawValue.capitalized) \(action.rawValue) sent at intensity \(force); awaiting Amber acknowledgement"
                self.reconcileGripperSubmissions(from: self.snapshot)
            } catch {
                guard let self, self.gripperInputGeneration == generation else { return }
                self.gripperSubmissions.removeValue(forKey: arm)
                self.gripperControlStatusMessage = error.localizedDescription
                self.drainDeferredGripperReleases()
            }
        }
    }

    private func reconcileGripperSubmissions(from snapshot: RobotSessionSnapshot) {
        let now = ProcessInfo.processInfo.systemUptime
        for arm in RobotArmSide.allCases {
            guard var tracking = gripperSubmissions[arm] else { continue }
            let control = snapshot.gripperTelemetry.control(for: arm)
            if let messageID = tracking.messageID {
                if control.pendingCommandMessageID == messageID {
                    tracking.observedPending = true
                    gripperSubmissions[arm] = tracking
                    continue
                }
                if control.lastDisposition?.requestMessageID == messageID {
                    gripperSubmissions.removeValue(forKey: arm)
                } else if control.lastTimedOutCommandMessageID == messageID {
                    gripperSubmissions.removeValue(forKey: arm)
                    gripperControlStatusMessage =
                        "\(arm.rawValue.capitalized) acknowledgement timed out; physical outcome unknown—supervise before retry"
                } else if tracking.observedPending
                    || now - tracking.startedAtUptime >= 2.5
                {
                    gripperSubmissions.removeValue(forKey: arm)
                    gripperControlStatusMessage =
                        "\(arm.rawValue.capitalized) acknowledgement ended without a terminal result; physical outcome unknown"
                }
            } else if now - tracking.startedAtUptime >= 2.5 {
                gripperSubmissions.removeValue(forKey: arm)
                gripperControlStatusMessage =
                    "\(arm.rawValue.capitalized) send did not finish; physical outcome unknown"
            }
        }
        drainDeferredGripperReleases()
    }

    private func drainDeferredGripperReleases() {
        let now = ProcessInfo.processInfo.systemUptime
        expireDeferredGripperReleases(now: now)
        guard sceneIsActive,
            gripperDeadManInputIsFresh(at: now),
            !snapshot.safety.emergencyStopIsLatched
        else { return }

        for arm in RobotArmSide.allCases {
            guard deferredGripperReleaseDeadlines[arm] != nil,
                gripperSubmissions[arm] == nil,
                snapshot.gripperTelemetry.control(for: arm).pendingCommandMessageID == nil
            else { continue }
            let triggerIsHeld = arm == .left
                ? latestGameControllerSample.leftGripperClosed
                : latestGameControllerSample.rightGripperClosed
            guard !triggerIsHeld else { continue }
            deferredGripperReleaseDeadlines.removeValue(forKey: arm)
            submitGripper(
                arm: arm,
                action: .release,
                deadManIsHeld: true,
                isDeferredReleaseRetry: true
            )
        }
    }

    private func expireDeferredGripperReleases(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let expired = deferredGripperReleaseDeadlines.compactMap { arm, deadline in
            deadline <= now ? arm : nil
        }
        for arm in expired {
            deferredGripperReleaseDeadlines.removeValue(forKey: arm)
            gripperControlStatusMessage =
                "\(arm.rawValue.capitalized) release retry expired before dispatch; physical state unknown—supervise and retry"
        }
    }

    private func clearGripperInputTracking() {
        gripperInputGeneration &+= 1
        gripperDeadManWasHeld = false
        lastLeftGripperTrigger = nil
        lastRightGripperTrigger = nil
        gripperSubmissions.removeAll()
        deferredGripperReleaseDeadlines.removeAll()
    }

    private func gripperDeadManInputIsFresh(
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard latestGameControllerSample.leftSpatialControllerIsConnected,
            latestGameControllerSample.rightSpatialControllerIsConnected,
            latestGameControllerSample.leftSpatialGripIsHeld,
            latestGameControllerSample.rightSpatialGripIsHeld,
            let receivedAt = latestGameControllerSampleAtUptime
        else { return false }
        return (0 ... 0.25).contains(now - receivedAt)
    }

    private func acceptHeadOrientation(_ sample: HeadOrientationSample) {
        latestHeadOrientation = sample
        guard sceneIsActive, latestGameControllerSample.isConnected,
              latestGameControllerSample.deadManIsHeld else { return }
        sendCombinedControllerSample()
    }

    private func sendCombinedControllerSample() {
        guard activeControlDomain == .drive else { return }
        let sample = latestGameControllerSample
        inputSequence &+= 1
        // The two controller sticks are direct tread demands. Convert to the protocol's
        // linear/angular representation without losing either independent floating-point value.
        let linear = (sample.leftTread + sample.rightTread) * 0.5
        let angular = (sample.leftTread - sample.rightTread) * 0.5
        let controlSample = OperatorControlSample(
            sequence: inputSequence,
            source: .gameController,
            linear: linear * speedLimit,
            angular: angular * speedLimit,
            cameraPan: latestHeadOrientation.pan,
            cameraTilt: latestHeadOrientation.tilt,
            cameraControlIsActive: sample.deadManIsHeld && latestHeadOrientation.isTracked,
            leftGripperClosed: sample.leftGripperClosed,
            rightGripperClosed: sample.rightGripperClosed,
            torsoRotation: latestHeadOrientation.torsoRotation,
            controllerPoses: sample.controllerPoses,
            deadManIsHeld: sample.deadManIsHeld
        )
        let session = session
        Task {
            await session.updateOperatorInput(controlSample)
        }
    }

    private func refreshStatusMessage(from snapshot: RobotSessionSnapshot) {
        if snapshot.connection.phase == .failed
            || snapshot.connection.phase == .disconnected
            || !snapshot.safety.isArmed
            || snapshot.safety.emergencyStopIsLatched
        {
            virtualInputTask?.cancel()
            virtualInputTask = nil
        }
        if snapshot.connection.phase == .failed || snapshot.connection.phase == .disconnected {
            cancelVideoAction()
        }

        switch snapshot.connection.phase {
        case .disconnected:
            statusMessage = "Disconnected"
        case .connecting:
            statusMessage = "Connecting…"
        case .handshaking:
            statusMessage = "Negotiating protocol capabilities…"
        case .connected:
            statusMessage = snapshot.safety.inhibitReason?.description ?? "Motion control ready"
        case .disconnecting:
            statusMessage = "Disconnecting…"
        case .failed:
            statusMessage = snapshot.connection.failure?.message ?? "Connection failed"
        }

        synchronizeArmWorkflow(from: snapshot)
        reconcileGripperSubmissions(from: snapshot)
        synchronizeRobotActionWorkflow(from: snapshot)

        synchronizeVideoPipeline(from: snapshot)
    }

    private func synchronizeRobotActionWorkflow(from snapshot: RobotSessionSnapshot) {
        guard snapshot.connection.isReady else {
            robotActionStatusMessage = "Action approvals are off"
            return
        }
        if let request = snapshot.robotActions.pendingRequest {
            if let status = snapshot.robotActions.lastStatus,
               status.callID == request.callID,
               status.state == .accepted || status.state == .executing {
                robotActionStatusMessage = status.detail
                    ?? "Cerebro is executing the approved action"
            } else {
                robotActionStatusMessage = "Review Cerebro's proposed \(request.action?.rawValue ?? "action")"
            }
        } else if snapshot.robotActions.isEnabled {
            robotActionStatusMessage = "Waiting for Cerebro action proposals"
        } else {
            robotActionStatusMessage = "Action approvals are off"
        }
    }

    private func synchronizeArmWorkflow(from snapshot: RobotSessionSnapshot) {
        guard snapshot.connection.isReady else {
            cancelArmMotionLocally()
            pairedControllerGripGestureWasHeld = false
            pairedReleaseHoldMessageIDs.removeAll()
            pairedReleaseHoldAwaitingArms.removeAll()
            latestGameControllerSampleAtUptime = nil
            activeControlDomain = .drive
            lastHandledArmDispositionIDs.removeAll()
            for arm in RobotArmSide.allCases {
                updateArmWorkflow(for: arm) { workflow in
                    workflow.draftPositions = []
                    workflow.draftBaselineSequence = nil
                    workflow.statusMessage = "Connect to Cerebro for supervised arm control"
                }
            }
            return
        }

        for arm in RobotArmSide.allCases {
            let control = snapshot.armTelemetry.controlState(for: arm)
            if control.localControlIsArmed,
                let authority = control.authorityState,
                authority.state == .granted
            {
                activeControlDomain = .amberArm
                if armWorkflow(for: arm).draftPositions.isEmpty,
                    authority.baselinePositionsRadians.count == RobotArmTargetIntent.jointCount
                {
                    updateArmWorkflow(for: arm) { workflow in
                        workflow.draftPositions = authority.baselinePositionsRadians
                        workflow.draftBaselineSequence = authority.baselineSequence
                        workflow.statusMessage =
                            "Authority granted; draft initialized from captured baseline"
                    }
                }
            }

            if let disposition = control.lastDisposition,
                disposition.messageID != lastHandledArmDispositionIDs[arm]
            {
                lastHandledArmDispositionIDs[arm] = disposition.messageID
                setArmControlStatusMessage(disposition.detail, for: arm)

                reconcilePairedReleaseHold(for: arm, disposition: disposition)

                if armMotionTasks[arm] != nil {
                    switch disposition.disposition {
                    case .acceptedForExecution, .executing, .completedMeasured:
                        break
                    default:
                        if armMotionInputs[arm] == .pairedControllers {
                            failPairedControllerMotion(reason: "terminal_arm_disposition")
                        } else {
                            endArmMotion(for: arm, reason: "terminal_arm_disposition")
                        }
                    }
                }
            }
        }

        if !hasAnyActiveArmControl {
            activeControlDomain = .drive
        }
    }

    private func synchronizeVideoPipeline(from snapshot: RobotSessionSnapshot) {
        let desiredDescriptor =
            sceneIsActive && snapshot.connection.isReady
            ? snapshot.videoStreams.first
            : nil
        guard desiredDescriptor != activeVideoDescriptor else { return }

        activeVideoDescriptor = desiredDescriptor
        videoLifecycleTask?.cancel()
        let videoPipeline = videoPipeline
        let session = session
        if let desiredDescriptor,
            let sessionID = snapshot.connection.handshake?.sessionID
        {
            videoLifecycleTask = Task {
                guard !Task.isCancelled else { return }
                await videoPipeline.start(
                    stream: desiredDescriptor,
                    sessionID: sessionID,
                    session: session
                )
            }
        } else {
            videoLifecycleTask = Task {
                guard !Task.isCancelled else { return }
                await videoPipeline.stop()
            }
        }
    }

    private func stopVideoPipeline() {
        activeVideoDescriptor = nil
        videoLifecycleTask?.cancel()
        let videoPipeline = videoPipeline
        videoLifecycleTask = Task {
            guard !Task.isCancelled else { return }
            await videoPipeline.stop()
        }
    }

    private func finishAction(_ id: UUID) {
        guard actionID == id else { return }
        actionID = nil
        actionTask = nil
    }

    private func finishVideoAction(_ id: UUID) {
        guard videoActionID == id else { return }
        videoActionID = nil
        videoActionTask = nil
        videoActionIsPending = false
    }

    private func cancelVideoAction() {
        videoActionID = nil
        videoActionTask?.cancel()
        videoActionTask = nil
        videoActionIsPending = false
    }
}
