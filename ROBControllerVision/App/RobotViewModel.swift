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
    @ObservationIgnored private var latestHeadOrientation = HeadOrientationSample.unavailable

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
            await session.connect(using: simulator)
            self?.finishAction(id)
        }
    }

    func disconnect() {
        endVirtualMotion()
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
        if !shouldArm {
            endVirtualMotion()
        }
        let session = session
        Task {
            await session.setArmed(shouldArm)
        }
    }

    func emergencyStop() {
        endVirtualMotion()
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
        guard sceneIsActive,
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

    private func acceptHeadOrientation(_ sample: HeadOrientationSample) {
        latestHeadOrientation = sample
        guard sceneIsActive, latestGameControllerSample.isConnected,
              latestGameControllerSample.deadManIsHeld else { return }
        sendCombinedControllerSample()
    }

    private func sendCombinedControllerSample() {
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

        synchronizeVideoPipeline(from: snapshot)
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
