import Foundation

public actor SimulatedRobotEndpoint: RobotTransport, RobotVideoDataTransport {
    public struct Configuration: Sendable {
        public var connectDelay: Duration
        public var telemetryInterval: Duration
        public var watchdogTimeout: Duration
        public var initialBatteryLevel: Double
        public var cameras: [CameraDescriptor]

        public init(
            connectDelay: Duration = .milliseconds(350),
            telemetryInterval: Duration = .milliseconds(200),
            watchdogTimeout: Duration = .milliseconds(350),
            initialBatteryLevel: Double = 0.84,
            cameras: [CameraDescriptor] = [
                CameraDescriptor(
                    id: CameraID(rawValue: "front"),
                    name: "Front Camera",
                    supportedCodecs: [.h264, .jpeg],
                    maximumWidth: 1_920,
                    maximumHeight: 1_080,
                    maximumFramesPerSecond: 30
                )
            ]
        ) {
            self.connectDelay = connectDelay
            self.telemetryInterval = telemetryInterval
            self.watchdogTimeout = watchdogTimeout
            self.initialBatteryLevel = initialBatteryLevel
            self.cameras = cameras
        }
    }

    public nonisolated let descriptor: RobotEndpointDescriptor

    private let configuration: Configuration
    private let videoDataSource: (any RobotVideoDataSource)?
    private var eventContinuation: AsyncStream<RobotEvent>.Continuation?
    private let clock = ContinuousClock()

    private var isConnected = false
    private var connectOperationID: UUID?
    private var disconnectOperationID: UUID?
    private var disconnectTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    private var isArmed = false
    private var emergencyStopIsLatched = false
    private var lastSequence: UInt64?
    private var motion = MotionVector.stopped
    private var motionDeadline: ContinuousClock.Instant?
    private var pose = RobotPose()
    private var batteryLevel: Double
    private var streams: [VideoSubscriptionID: VideoStreamDescriptor] = [:]
    private var telemetryTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    public init(
        descriptor: RobotEndpointDescriptor = RobotEndpointDescriptor(
            name: "ROB Simulator",
            serviceType: "_robctl._udp",
            transport: .simulated
        ),
        configuration: Configuration = Configuration(),
        videoDataSource: (any RobotVideoDataSource)? = nil
    ) {
        self.descriptor = descriptor
        self.configuration = configuration
        self.videoDataSource = videoDataSource
        self.batteryLevel = min(1, max(0, configuration.initialBatteryLevel))
    }

    deinit {
        telemetryTask?.cancel()
        watchdogTask?.cancel()
        disconnectTask?.cancel()
        eventContinuation?.finish()
    }

    public func events() async -> AsyncStream<RobotEvent> {
        eventContinuation?.finish()
        let pair = AsyncStream<RobotEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        eventContinuation = pair.continuation
        return pair.stream
    }

    public func connect() async throws -> RobotHandshake {
        guard !isConnected, connectOperationID == nil, disconnectTask == nil else {
            throw RobotTransportError.alreadyConnected
        }

        let operationID = UUID()
        connectOperationID = operationID
        do {
            try await clock.sleep(for: configuration.connectDelay)
            try Task.checkCancellation()
            guard connectOperationID == operationID, disconnectTask == nil else {
                throw CancellationError()
            }
        } catch {
            if connectOperationID == operationID {
                connectOperationID = nil
            }
            throw error
        }

        connectOperationID = nil
        isConnected = true
        isArmed = false
        lastSequence = nil
        motion = .stopped
        motionDeadline = nil
        let sessionID = UUID()
        activeSessionID = sessionID
        startBackgroundTasks()

        let handshake = RobotHandshake(
            sessionID: sessionID,
            robotName: descriptor.name,
            capabilities: RobotCapabilities(cameras: advertisedCameras),
            safetyState: MotionSafetyState(
                isArmed: false,
                emergencyStopIsLatched: emergencyStopIsLatched,
                inhibitReason: emergencyStopIsLatched ? .emergencyStop : .operatorDisarmed
            )
        )
        eventContinuation?.yield(.connected(handshake))
        return handshake
    }

    public func disconnect() async {
        if let disconnectTask, let disconnectOperationID {
            await disconnectTask.value
            completeDisconnect(operationID: disconnectOperationID)
            return
        }
        guard isConnected || connectOperationID != nil else { return }

        let operationID = UUID()
        disconnectOperationID = operationID
        connectOperationID = nil
        let closingSessionID = activeSessionID
        isConnected = false
        activeSessionID = nil
        isArmed = false
        motion = .stopped
        motionDeadline = nil
        streams.removeAll()
        telemetryTask?.cancel()
        watchdogTask?.cancel()
        telemetryTask = nil
        watchdogTask = nil
        eventContinuation?.yield(.disconnected(reason: "Simulator disconnected"))
        eventContinuation?.finish()
        eventContinuation = nil

        let videoDataSource = videoDataSource
        let task = Task {
            if let closingSessionID {
                await videoDataSource?.closeAllVideoDataStreams(sessionID: closingSessionID)
            }
        }
        disconnectTask = task
        await task.value
        completeDisconnect(operationID: operationID)
    }

    private func completeDisconnect(operationID: UUID) {
        guard disconnectOperationID == operationID else { return }
        disconnectTask = nil
        disconnectOperationID = nil
    }

    public func send(_ envelope: RobotCommandEnvelope) async throws {
        guard isConnected else { throw RobotTransportError.notConnected }
        guard envelope.sessionID == activeSessionID else {
            throw RobotTransportError.invalidState("Command belongs to a stale robot session.")
        }
        guard envelope.protocolVersion == RobotCommandEnvelope.currentProtocolVersion else {
            throw RobotTransportError.invalidState("Unsupported protocol version \(envelope.protocolVersion).")
        }

        if !envelope.command.isEmergencyStop {
            let ageMilliseconds = Date().timeIntervalSince(envelope.issuedAt) * 1_000
            guard ageMilliseconds <= Double(envelope.leaseMilliseconds) else {
                throw RobotTransportError.commandExpired
            }
            if let lastSequence, envelope.sequence <= lastSequence {
                throw RobotTransportError.staleCommand
            }
        }
        lastSequence = max(lastSequence ?? 0, envelope.sequence)

        switch envelope.command {
        case .setArmed(let armed):
            if armed && emergencyStopIsLatched {
                throw RobotTransportError.invalidState("Reset the emergency stop before arming motion.")
            }
            isArmed = armed
            if !armed {
                stopMotion(reason: .operatorDisarmed)
            }
            eventContinuation?.yield(.safety(.armedChanged(armed)))

        case .drive(let requestedMotion, _, _, _, _):
            guard isArmed && !emergencyStopIsLatched else {
                stopMotion(reason: emergencyStopIsLatched ? .emergencyStop : .operatorDisarmed)
                throw RobotTransportError.invalidState("Motion command rejected while motion is inhibited.")
            }
            motion = requestedMotion
            motionDeadline = clock.now.advanced(
                by: min(
                    .milliseconds(envelope.leaseMilliseconds),
                    configuration.watchdogTimeout
                )
            )

        case .stop(let reason, _):
            stopMotion(reason: reason)

        case .emergencyStop:
            emergencyStopIsLatched = true
            isArmed = false
            stopMotion(reason: .emergencyStop)
            eventContinuation?.yield(.safety(.emergencyStopChanged(true)))
            eventContinuation?.yield(.safety(.armedChanged(false)))

        case .resetEmergencyStop:
            emergencyStopIsLatched = false
            isArmed = false
            stopMotion(reason: .operatorDisarmed)
            eventContinuation?.yield(.safety(.emergencyStopChanged(false)))
            eventContinuation?.yield(.safety(.armedChanged(false)))

        case .video(let message):
            await handleVideo(message, sessionID: envelope.sessionID)

        case .operatorText:
            // The simulator acknowledges speech/text without synthesizing audio.
            break
        }

        eventContinuation?.yield(.commandAcknowledged(envelope.id))
    }

    private func startBackgroundTasks() {
        telemetryTask?.cancel()
        watchdogTask?.cancel()

        let telemetryInterval = configuration.telemetryInterval
        telemetryTask = Task { [weak self] in
            let timer = ContinuousClock()
            while !Task.isCancelled {
                do {
                    try await timer.sleep(for: telemetryInterval)
                } catch {
                    return
                }
                await self?.emitTelemetry(for: telemetryInterval)
            }
        }

        watchdogTask = Task { [weak self] in
            let timer = ContinuousClock()
            while !Task.isCancelled {
                do {
                    try await timer.sleep(for: .milliseconds(25))
                } catch {
                    return
                }
                await self?.evaluateWatchdog()
            }
        }
    }

    private func emitTelemetry(for interval: Duration) {
        guard isConnected else { return }

        let seconds = interval.secondsValue
        let linearVelocity = Double(motion.linear) * 0.6
        let angularVelocity = Double(motion.angular) * 0.9
        pose.headingRadians += angularVelocity * seconds
        pose.xMeters += cos(pose.headingRadians) * linearVelocity * seconds
        pose.yMeters += sin(pose.headingRadians) * linearVelocity * seconds
        batteryLevel = max(0, batteryLevel - (motion.isStopped ? 0.00001 : 0.00008))

        eventContinuation?.yield(
            .telemetry(
                RobotTelemetry(
                    batteryLevel: batteryLevel,
                    pose: pose,
                    linearVelocity: linearVelocity,
                    angularVelocity: angularVelocity
                )
            )
        )
    }

    private func evaluateWatchdog() {
        guard isConnected,
            !motion.isStopped,
            let motionDeadline,
            clock.now >= motionDeadline
        else { return }

        stopMotion(reason: .robotWatchdog)
    }

    private func stopMotion(reason: MotionInhibitReason) {
        let wasMoving = !motion.isStopped
        motion = .stopped
        motionDeadline = nil
        if wasMoving || reason == .emergencyStop || reason == .robotWatchdog {
            eventContinuation?.yield(.safety(.motionStopped(reason)))
        }
    }

    public func openVideoDataStream(
        sessionID: UUID,
        stream: VideoStreamDescriptor
    ) async throws -> RobotVideoDataChannel {
        guard isConnected, sessionID == activeSessionID else {
            throw VideoDataTransportError.inactiveSession
        }
        guard streams[stream.id] == stream else {
            throw VideoDataTransportError.subscriptionNotFound(stream.id)
        }
        guard let videoDataSource else {
            throw VideoDataTransportError.unavailable
        }
        let channel = try await videoDataSource.openVideoDataStream(
            sessionID: sessionID,
            stream: stream
        )
        guard channel.sessionID == sessionID, channel.descriptor == stream else {
            await videoDataSource.closeVideoDataChannel(channel.id)
            throw VideoDataTransportError.channelMetadataMismatch
        }
        guard isConnected,
            activeSessionID == sessionID,
            streams[stream.id] == stream
        else {
            await videoDataSource.closeVideoDataChannel(channel.id)
            throw VideoDataTransportError.inactiveSession
        }
        return channel
    }

    public func closeVideoDataChannel(_ id: UUID) async {
        await videoDataSource?.closeVideoDataChannel(id)
    }

    private func handleVideo(_ message: VideoControlMessage, sessionID: UUID) async {
        switch message {
        case .subscribe(let request):
            let response = negotiate(request)
            if case .accepted(let stream) = response {
                streams[stream.id] = stream
            }
            eventContinuation?.yield(.video(.subscription(response)))

        case .unsubscribe(let request):
            if streams.removeValue(forKey: request.id) != nil {
                eventContinuation?.yield(.video(.ended(id: request.id, reason: "Unsubscribed")))
                await videoDataSource?.closeVideoDataStreams(
                    sessionID: sessionID,
                    subscriptionID: request.id
                )
            }

        case .feedback(let feedback):
            guard streams[feedback.id] != nil else { return }
            await videoDataSource?.handleVideoFeedback(feedback, sessionID: sessionID)
        }
    }

    private func negotiate(_ request: VideoSubscriptionRequest) -> VideoSubscriptionResponse {
        guard streams[request.id] == nil else {
            return .rejected(id: request.id, reason: .duplicateSubscriptionID)
        }
        guard request.constraints.isValid else {
            return .rejected(id: request.id, reason: .invalidConstraints)
        }
        guard let videoDataSource,
            videoDataSource.supportedDeliveryModes.contains(request.delivery)
        else {
            return .rejected(id: request.id, reason: .deliveryUnavailable)
        }
        guard let camera = advertisedCameras.first(where: { $0.id == request.cameraID }) else {
            return .rejected(id: request.id, reason: .cameraUnavailable)
        }
        guard let codec = request.preferredCodecs.first(where: camera.supportedCodecs.contains) else {
            return .rejected(id: request.id, reason: .codecUnavailable)
        }
        guard (codec == .jpeg) == (request.delivery == .jpegFrames) else {
            return .rejected(id: request.id, reason: .deliveryUnavailable)
        }

        return .accepted(
            VideoStreamDescriptor(
                id: request.id,
                cameraID: camera.id,
                codec: codec,
                width: min(camera.maximumWidth, request.constraints.maximumWidth),
                height: min(camera.maximumHeight, request.constraints.maximumHeight),
                framesPerSecond: min(
                    camera.maximumFramesPerSecond,
                    request.constraints.maximumFramesPerSecond
                ),
                bitrate: min(request.constraints.maximumBitrate, videoDataSource.maximumBitrate),
                delivery: request.delivery
            )
        )
    }

    private var advertisedCameras: [CameraDescriptor] {
        guard let videoDataSource else { return [] }
        return configuration.cameras.compactMap { camera in
            var camera = camera
            camera.supportedCodecs = camera.supportedCodecs.filter(
                videoDataSource.supportedCodecs.contains
            )
            return camera.supportedCodecs.isEmpty ? nil : camera
        }
    }
}

extension RobotCommand {
    fileprivate var isEmergencyStop: Bool {
        if case .emergencyStop = self { return true }
        return false
    }
}

extension Duration {
    fileprivate var secondsValue: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
