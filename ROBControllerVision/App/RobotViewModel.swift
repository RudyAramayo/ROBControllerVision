import Foundation
import Observation
import ROBControlCore
import ROBVideoPipeline

@MainActor
@Observable
final class RobotViewModel {
    private(set) var snapshot = RobotSessionSnapshot()
    private(set) var statusMessage = "Ready to connect to the simulator"
    var speedLimit: Float = 0.65

    let gameController: GameControllerInput
    let videoPipeline: VideoPipelineCoordinator

    @ObservationIgnored private let session: RobotSession
    @ObservationIgnored private let simulator: SimulatedRobotEndpoint
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var virtualInputTask: Task<Void, Never>?
    @ObservationIgnored private var videoLifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var activeVideoDescriptor: VideoStreamDescriptor?
    @ObservationIgnored private var sceneIsActive = false
    @ObservationIgnored private var inputSequence: UInt64 = 0

    init(
        session: RobotSession = RobotSession(),
        simulator: SimulatedRobotEndpoint? = nil,
        videoPipeline: VideoPipelineCoordinator = VideoPipelineCoordinator()
    ) {
        self.session = session
        self.simulator =
            simulator
            ?? SimulatedRobotEndpoint(videoDataSource: SyntheticVideoDataSource())
        self.videoPipeline = videoPipeline
        self.gameController = GameControllerInput()
        self.gameController.onSample = { [weak self] sample in
            self?.acceptGameController(sample)
        }
    }

    deinit {
        updatesTask?.cancel()
        actionTask?.cancel()
        virtualInputTask?.cancel()
        videoLifecycleTask?.cancel()
    }

    func start() {
        guard updatesTask == nil else { return }
        gameController.start()
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
        actionTask?.cancel()
        actionTask = nil
        endVirtualMotion()
        stopVideoPipeline()
        gameController.stop()
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
            connectToSimulator()
        }
    }

    func connectToSimulator() {
        guard actionTask == nil else { return }
        statusMessage = "Connecting to ROB Simulator…"
        let session = session
        let simulator = simulator
        actionTask = Task { [weak self] in
            await session.connect(using: simulator)
            self?.actionTask = nil
        }
    }

    func disconnect() {
        endVirtualMotion()
        stopVideoPipeline()
        actionTask?.cancel()
        let session = session
        actionTask = Task { [weak self] in
            await session.disconnect()
            self?.actionTask = nil
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

    func toggleVideoSubscription() {
        let session = session
        if let activeStream = snapshot.videoStreams.first {
            Task { [weak self] in
                do {
                    try await session.unsubscribeVideo(activeStream.id)
                    self?.statusMessage = "Video subscription stopped"
                } catch {
                    self?.statusMessage = error.localizedDescription
                }
            }
            return
        }

        guard let camera = snapshot.connection.handshake?.capabilities.cameras.first else {
            statusMessage = "The connected robot did not advertise a camera"
            return
        }

        let request = Self.syntheticVideoRequest(cameraID: camera.id)
        Task { [weak self] in
            do {
                let response = try await session.subscribeVideo(request)
                switch response {
                case .accepted:
                    self?.statusMessage = "Video subscription negotiated"
                case .rejected(_, let reason):
                    self?.statusMessage = "Video subscription rejected: \(reason.rawValue)"
                }
            } catch {
                self?.statusMessage = error.localizedDescription
            }
        }
    }

    private static func syntheticVideoRequest(
        cameraID: CameraID
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
            delivery: .quicDatagrams
        )
    }

    #if DEBUG
        private func startVideoSmokeTest() {
            guard actionTask == nil else { return }
            let session = session
            let simulator = simulator
            actionTask = Task { [weak self] in
                await session.connect(using: simulator)
                let snapshot = await session.currentSnapshot()
                guard let cameraID = snapshot.connection.handshake?.capabilities.cameras.first?.id else {
                    self?.statusMessage = "Video smoke test found no camera"
                    self?.actionTask = nil
                    return
                }
                do {
                    _ = try await session.subscribeVideo(
                        Self.syntheticVideoRequest(cameraID: cameraID)
                    )
                } catch {
                    self?.statusMessage = "Video smoke test failed: \(error.localizedDescription)"
                }
                self?.actionTask = nil
            }
        }
    #endif

    func beginVirtualMotion(linear: Float, angular: Float) {
        guard snapshot.connection.isReady,
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
        if !active {
            endVirtualMotion()
            stopVideoPipeline()
        } else {
            synchronizeVideoPipeline(from: snapshot)
        }
        let session = session
        Task {
            await session.setSceneActive(active)
        }
    }

    private func acceptGameController(_ sample: GameControllerSample) {
        guard sample.isConnected else {
            let session = session
            Task {
                await session.invalidateInput(reason: .controllerDisconnected)
            }
            return
        }

        inputSequence &+= 1
        let controlSample = OperatorControlSample(
            sequence: inputSequence,
            source: .gameController,
            linear: sample.linear * speedLimit,
            angular: sample.angular * speedLimit,
            cameraPan: sample.cameraPan,
            cameraTilt: sample.cameraTilt,
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
}
