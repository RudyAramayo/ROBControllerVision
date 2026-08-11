import Foundation
import ROBControlCore

/// Production Vision Pro adapter for Cerebro.
///
/// One actor owns two independently authenticated QUIC connections. `robctl/2` is authoritative
/// for safety and supplies the live session UUID; `robvideo/1` carries only camera negotiation,
/// feedback, and encoded media. Video pressure therefore never enters the motion-command queue.
public actor CerebroRobotTransport: RobotTransport, RobotVideoDataTransport {
    public nonisolated let descriptor: RobotEndpointDescriptor
    public nonisolated let credential: ROBCerebroCredential

    private let controlClient: ROBControlClient
    private let videoDiscovery: ROBVideoDiscovery
    private var videoClient: ROBVideoClient?

    private var connectionAttemptID: UUID?
    private var activeSessionID: UUID?
    private var lastCommandSequence: UInt64 = 0
    private var isDisconnecting = false
    private var controlEventTask: Task<Void, Never>?
    private var videoEventTask: Task<Void, Never>?
    private var activeVideoStreams: Set<VideoSubscriptionID> = []
    private var eventSubscribers: [UUID: AsyncStream<RobotEvent>.Continuation] = [:]

    public init(credential: ROBCerebroCredential) {
        self.credential = credential
        controlClient = ROBControlClient(credential: credential)
        videoDiscovery = ROBVideoDiscovery()
        descriptor = RobotEndpointDescriptor(
            id: credential.robotID,
            name: "Cerebro",
            serviceType: ROBCerebroPairingStore.controlServiceType,
            transport: .quic
        )
    }

    deinit {
        controlEventTask?.cancel()
        videoEventTask?.cancel()
        for continuation in eventSubscribers.values {
            continuation.finish()
        }
    }

    public func events() -> AsyncStream<RobotEvent> {
        let id = UUID()
        let pair = AsyncStream<RobotEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        eventSubscribers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventSubscriber(id) }
        }
        return pair.stream
    }

    public func connect() async throws -> RobotHandshake {
        guard connectionAttemptID == nil, activeSessionID == nil, !isDisconnecting else {
            throw RobotTransportError.alreadyConnected
        }
        guard credential.isValid, credential.effectiveRole == .operatorController else {
            throw ROBCerebroTransportError.authorizationFailed
        }

        let attemptID = UUID()
        connectionAttemptID = attemptID
        startControlEventMonitor()

        do {
            let sessionID = try await controlClient.connect()
            try ensureCurrentConnectionAttempt(attemptID)

            var cameras: [CameraDescriptor] = []
            do {
                let discoveredVideo = try await videoDiscovery.discover(
                    credential: credential,
                    timeout: .seconds(3)
                )
                try ensureCurrentConnectionAttempt(attemptID)

                let videoClient = ROBVideoClient(
                    endpoint: discoveredVideo.endpoint,
                    credential: credential
                )
                self.videoClient = videoClient
                startVideoEventMonitor(client: videoClient)
                cameras = try await videoClient.connect()
                try ensureCurrentConnectionAttempt(attemptID)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw error
                }
                try ensureCurrentConnectionAttempt(attemptID)
                await tearDownVideoConnection()
            }

            guard await controlClient.liveSessionID() == sessionID else {
                throw ROBCerebroTransportError.connectionFailed(
                    "The bound control session ended while the video service was connecting."
                )
            }

            activeSessionID = sessionID
            lastCommandSequence = 0
            connectionAttemptID = nil

            let handshake = RobotHandshake(
                protocolVersion: RobotCommandEnvelope.currentProtocolVersion,
                sessionID: sessionID,
                robotName: descriptor.name,
                capabilities: RobotCapabilities(
                    supportsMotionControl: true,
                    // The network stop below brakes and releases authority; the independently
                    // wired physical emergency stop remains the definitive emergency mechanism.
                    supportsEmergencyStop: false,
                    cameras: cameras
                ),
                safetyState: MotionSafetyState(
                    isArmed: false,
                    emergencyStopIsLatched: false,
                    inhibitReason: .operatorDisarmed
                )
            )
            publish(.connected(handshake))
            return handshake
        } catch {
            if connectionAttemptID == attemptID {
                connectionAttemptID = nil
            }
            await tearDownConnections()
            throw Self.normalizedError(error)
        }
    }

    public func disconnect() async {
        guard !isDisconnecting else { return }
        isDisconnecting = true
        connectionAttemptID = nil

        if let sessionID = activeSessionID,
            await controlClient.liveSessionID() == sessionID
        {
            try? await controlClient.sendApplicationData(
                ROBLegacyControllerPayload.stoppedSnapshot(senderID: credential.controllerID)
            )
            try? await controlClient.sendApplicationData(
                ROBLegacyControllerPayload.releaseMotionAuthority(senderID: credential.controllerID)
            )
        }

        await tearDownConnections()
        activeSessionID = nil
        lastCommandSequence = 0
        activeVideoStreams.removeAll()
        isDisconnecting = false
    }

    public func send(_ envelope: RobotCommandEnvelope) async throws {
        guard let activeSessionID,
            envelope.sessionID == activeSessionID,
            await controlClient.liveSessionID() == activeSessionID
        else {
            throw RobotTransportError.notConnected
        }
        guard envelope.sequence > lastCommandSequence else {
            throw RobotTransportError.staleCommand
        }
        guard Self.commandIsFresh(envelope) else {
            throw RobotTransportError.commandExpired
        }
        lastCommandSequence = envelope.sequence

        switch envelope.command {
        case .setArmed(true):
            try await controlClient.sendApplicationData(
                ROBLegacyControllerPayload.requestMotionAuthority(senderID: credential.controllerID)
            )

        case .setArmed(false):
            try await sendStoppedAndReleaseAuthority()

        case .drive(let motion, let camera, let grippers, let controllerPoses):
            try await controlClient.sendApplicationData(
                ROBLegacyControllerPayload.controllerSnapshot(
                    motion: motion,
                    camera: camera,
                    grippers: grippers,
                    senderID: credential.controllerID,
                    brakeIsLocked: false,
                    neckControlActive: camera.isActive,
                    controllerPoses: controllerPoses
                )
            )

        case .stop(_, let controllerPoses):
            try await controlClient.sendApplicationData(
                ROBLegacyControllerPayload.stoppedSnapshot(
                    senderID: credential.controllerID,
                    controllerPoses: controllerPoses
                )
            )

        case .emergencyStop:
            try await sendStoppedAndReleaseAuthority()

        case .resetEmergencyStop:
            // Cerebro's established controller payload has no remote physical-E-stop reset.
            // Resetting the app latch deliberately leaves motion disarmed until a new arm request.
            break

        case .video(let message):
            guard let videoClient else {
                throw ROBCerebroTransportError.videoUnavailable
            }
            switch message {
            case .subscribe(let request):
                _ = try await videoClient.subscribe(
                    sessionID: activeSessionID,
                    request: request
                )
            case .unsubscribe(let request):
                try await videoClient.unsubscribe(
                    sessionID: activeSessionID,
                    id: request.id
                )
            case .feedback(let feedback):
                try await videoClient.sendFeedback(
                    sessionID: activeSessionID,
                    feedback: feedback
                )
            }
        }
    }

    public func openVideoDataStream(
        sessionID: UUID,
        stream: VideoStreamDescriptor
    ) async throws -> RobotVideoDataChannel {
        guard sessionID == activeSessionID, let videoClient else {
            throw VideoDataTransportError.inactiveSession
        }
        return try await videoClient.openVideoDataStream(
            sessionID: sessionID,
            stream: stream
        )
    }

    public func closeVideoDataChannel(_ id: UUID) async {
        await videoClient?.closeVideoDataChannel(id)
    }

    private func sendStoppedAndReleaseAuthority() async throws {
        try await controlClient.sendApplicationData(
            ROBLegacyControllerPayload.stoppedSnapshot(senderID: credential.controllerID)
        )
        try await controlClient.sendApplicationData(
            ROBLegacyControllerPayload.releaseMotionAuthority(senderID: credential.controllerID)
        )
    }

    private func startControlEventMonitor() {
        controlEventTask?.cancel()
        let controlClient = controlClient
        controlEventTask = Task { [weak self] in
            let events = await controlClient.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handleControlClientEvent(event)
            }
        }
    }

    private func startVideoEventMonitor(client: ROBVideoClient) {
        videoEventTask?.cancel()
        videoEventTask = Task { [weak self] in
            let events = await client.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handleVideoClientEvent(event, source: client)
            }
        }
    }

    private func handleControlClientEvent(_ event: ROBControlClientEvent) async {
        switch event {
        case .disconnected(let error):
            guard activeSessionID != nil, !isDisconnecting else { return }
            activeSessionID = nil
            lastCommandSequence = 0
            let streams = activeVideoStreams
            activeVideoStreams.removeAll()
            await videoClient?.disconnect()
            for id in streams {
                publish(.video(.ended(id: id, reason: "The bound control session ended.")))
            }
            publish(.disconnected(reason: error?.localizedDescription ?? "Cerebro disconnected."))

        case .stateChanged, .applicationData, .lidarTelemetry:
            break
        }
    }

    private func handleVideoClientEvent(
        _ event: ROBVideoClientEvent,
        source: ROBVideoClient
    ) async {
        guard videoClient === source else { return }
        switch event {
        case .subscriptionResponse(let sessionID, let response):
            guard sessionID == activeSessionID else { return }
            switch response {
            case .accepted(let stream):
                activeVideoStreams.insert(stream.id)
            case .rejected:
                break
            }
            publish(.video(.subscription(response)))

        case .streamEnded(let sessionID, let id, let reason):
            guard sessionID == activeSessionID else { return }
            activeVideoStreams.remove(id)
            publish(.video(.ended(id: id, reason: reason)))

        case .disconnected(let reason):
            videoEventTask?.cancel()
            videoEventTask = nil
            videoClient = nil
            let streams = activeVideoStreams
            activeVideoStreams.removeAll()
            for id in streams {
                publish(.video(.ended(id: id, reason: reason)))
            }
        }
    }

    private func tearDownConnections() async {
        await tearDownVideoConnection()
        controlEventTask?.cancel()
        controlEventTask = nil
        await controlClient.disconnect()
    }

    private func tearDownVideoConnection() async {
        videoEventTask?.cancel()
        videoEventTask = nil
        let videoClient = self.videoClient
        self.videoClient = nil
        await videoClient?.disconnect()
        await videoDiscovery.cancel()
        activeVideoStreams.removeAll()
    }

    private func ensureCurrentConnectionAttempt(_ id: UUID) throws {
        guard connectionAttemptID == id, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func publish(_ event: RobotEvent) {
        for continuation in eventSubscribers.values {
            continuation.yield(event)
        }
    }

    private func removeEventSubscriber(_ id: UUID) {
        eventSubscribers.removeValue(forKey: id)
    }

    private static func commandIsFresh(_ envelope: RobotCommandEnvelope) -> Bool {
        let nowMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let futureSkewAllowance: Int64 = 5_000
        guard envelope.issuedAtUnixMilliseconds <= nowMilliseconds + futureSkewAllowance else {
            return false
        }
        let expiry = envelope.issuedAtUnixMilliseconds.addingReportingOverflow(
            Int64(envelope.leaseMilliseconds)
        )
        return !expiry.overflow && nowMilliseconds <= expiry.partialValue
    }

    private static func normalizedError(_ error: Error) -> Error {
        if error is CancellationError {
            return ROBCerebroTransportError.cancelled
        }
        return error
    }
}
