import Foundation
@preconcurrency import Network
import ROBControlCore

/// Production Vision Pro adapter for Cerebro.
///
/// One actor owns the authoritative `robctl/2` connection plus an isolated authenticated
/// `robvideo/1` connection for each enabled camera. Control supplies the live session UUID;
/// media carries only camera negotiation, feedback, and encoded frames. Video pressure therefore
/// never enters the motion-command queue or another camera's ordered stream.
public actor CerebroRobotTransport: RobotTransport, RobotVideoDataTransport {
    public nonisolated let descriptor: RobotEndpointDescriptor
    public nonisolated let credential: ROBCerebroCredential

    private let controlClient: ROBControlClient
    private let videoDiscovery: ROBVideoDiscovery
    private var videoClient: ROBVideoClient?
    private var videoEndpoint: NWEndpoint?
    private var videoClientsByID: [UUID: ROBVideoClient] = [:]
    private var videoClientIDBySubscriptionID: [VideoSubscriptionID: UUID] = [:]
    private var videoClientIDByDataChannelID: [UUID: UUID] = [:]
    private var videoUnavailableReason: String?

    private var connectionAttemptID: UUID?
    private var activeSessionID: UUID?
    private var lastCommandSequence: UInt64 = 0
    private var isDisconnecting = false
    private var controlEventTask: Task<Void, Never>?
    private var videoEventTasks: [UUID: Task<Void, Never>] = [:]
    private var videoReconnectTask: Task<Void, Never>?
    private var videoReconnectAttempt = 0
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
        for task in videoEventTasks.values { task.cancel() }
        videoReconnectTask?.cancel()
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
        videoReconnectAttempt = 0
        startControlEventMonitor()

        do {
            let sessionID = try await controlClient.connect()
            try ensureCurrentConnectionAttempt(attemptID)

            var cameras: [CameraDescriptor] = []
            do {
                cameras = try await connectVideoService(
                    discoveryTimeout: .seconds(3),
                    controlSessionID: sessionID
                )
                try ensureCurrentConnectionAttempt(attemptID)
                if cameras.isEmpty {
                    throw ROBCerebroTransportError.videoUnavailable
                }
                videoUnavailableReason = nil
                videoReconnectAttempt = 0
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw error
                }
                try ensureCurrentConnectionAttempt(attemptID)
                videoUnavailableReason = Self.videoDiagnostic(from: error)
                await tearDownVideoConnection()
            }

            guard await controlClient.liveSessionID() == sessionID else {
                throw ROBCerebroTransportError.connectionFailed(
                    "The bound control session ended while the video service was connecting."
                )
            }
            try ensureCurrentConnectionAttempt(attemptID)

            activeSessionID = sessionID
            lastCommandSequence = 0
            connectionAttemptID = nil
            if videoClient == nil {
                cameras = []
            }

            let handshake = RobotHandshake(
                protocolVersion: RobotCommandEnvelope.currentProtocolVersion,
                sessionID: sessionID,
                robotName: descriptor.name,
                capabilities: Self.capabilities(
                    cameras: cameras,
                    videoUnavailableReason: videoUnavailableReason
                ),
                safetyState: MotionSafetyState(
                    isArmed: false,
                    emergencyStopIsLatched: false,
                    inhibitReason: .operatorDisarmed
                )
            )
            publish(.connected(handshake))
            if cameras.isEmpty {
                scheduleVideoReconnect()
            }
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
                ROBLegacyControllerPayload.stoppedSnapshot(
                    senderID: credential.controllerID,
                    reason: .disconnected
                )
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
            try await sendStoppedAndReleaseAuthority(reason: .operatorDisarmed)

        case .drive(let motion, let camera, let grippers, let torso, let controllerPoses):
            try await controlClient.sendApplicationData(
                ROBLegacyControllerPayload.controllerSnapshot(
                    motion: motion,
                    camera: camera,
                    grippers: grippers,
                    torso: torso,
                    senderID: credential.controllerID,
                    brakeIsLocked: false,
                    neckControlActive: camera.isActive,
                    controllerPoses: controllerPoses
                )
            )

        case .stop(let reason, let controllerPoses):
            try await controlClient.sendApplicationData(
                ROBLegacyControllerPayload.stoppedSnapshot(
                    senderID: credential.controllerID,
                    controllerPoses: controllerPoses,
                    reason: reason
                )
            )

        case .emergencyStop:
            try await sendStoppedAndReleaseAuthority(reason: .emergencyStop)

        case .resetEmergencyStop:
            // Cerebro's established controller payload has no remote physical-E-stop reset.
            // Resetting the app latch deliberately leaves motion disarmed until a new arm request.
            break

        case .armAuthority(let command):
            let data = try RobotArmWireCodec.encodeAuthorityIntent(
                arm: command.arm,
                operation: command.operation,
                messageID: envelope.id,
                senderID: credential.controllerID,
                sessionID: activeSessionID,
                sequence: envelope.sequence,
                issuedAtUnixMilliseconds: envelope.issuedAtUnixMilliseconds,
                leaseMilliseconds: envelope.leaseMilliseconds
            )
            try await controlClient.sendApplicationData(data)

        case .armTarget(let command):
            let data = try RobotArmWireCodec.encodeTargetIntent(
                command.target,
                messageID: envelope.id,
                senderID: credential.controllerID,
                sessionID: activeSessionID,
                sequence: envelope.sequence,
                issuedAtUnixMilliseconds: envelope.issuedAtUnixMilliseconds,
                leaseMilliseconds: envelope.leaseMilliseconds,
                authorityID: command.authorityID,
                deadManIsHeld: command.deadManIsHeld
            )
            try await controlClient.sendApplicationData(data)

        case .armHold(let command):
            let data = try RobotArmWireCodec.encodeHoldIntent(
                arm: command.arm,
                authorityID: command.authorityID,
                reason: command.reason,
                messageID: envelope.id,
                senderID: credential.controllerID,
                sessionID: activeSessionID,
                sequence: envelope.sequence,
                issuedAtUnixMilliseconds: envelope.issuedAtUnixMilliseconds,
                leaseMilliseconds: envelope.leaseMilliseconds
            )
            try await controlClient.sendApplicationData(data)

        case .gripper(let command):
            let data = try RobotGripperWireCodec.encodeCommandIntent(
                command.intent,
                messageID: envelope.id,
                senderID: credential.controllerID,
                sessionID: activeSessionID,
                sequence: envelope.sequence,
                issuedAtUnixMilliseconds: envelope.issuedAtUnixMilliseconds,
                leaseMilliseconds: envelope.leaseMilliseconds,
                deadManHeld: command.deadManIsHeld
            )
            try await controlClient.sendApplicationData(data)

        case .robotAction(let message):
            let controllerID = credential.controllerID.uuidString.lowercased()
            guard message.senderID.lowercased() == controllerID else {
                throw RobotTransportError.invalidState(
                    "Robot-action sender does not match the authenticated controller."
                )
            }
            try await controlClient.sendApplicationData(
                RobotActionWireCodec.archive(message)
            )

        case .video(let message):
            guard videoClient != nil || !videoClientsByID.isEmpty else {
                throw ROBCerebroTransportError.videoUnavailable
            }
            switch message {
            case .subscribe(let request):
                let (clientID, client) = try await acquireVideoClient(
                    for: request.id
                )
                videoClientIDBySubscriptionID[request.id] = clientID
                do {
                    _ = try await client.subscribe(
                        sessionID: activeSessionID,
                        request: request
                    )
                } catch {
                    if videoClientIDBySubscriptionID[request.id] == clientID {
                        videoClientIDBySubscriptionID.removeValue(forKey: request.id)
                    }
                    throw error
                }
            case .unsubscribe(let request):
                guard let client = videoClient(for: request.id) else {
                    throw VideoDataTransportError.subscriptionNotFound(request.id)
                }
                try await client.unsubscribe(
                    sessionID: activeSessionID,
                    id: request.id
                )
            case .feedback(let feedback):
                guard let client = videoClient(for: feedback.id) else {
                    throw VideoDataTransportError.subscriptionNotFound(feedback.id)
                }
                try await client.sendFeedback(
                    sessionID: activeSessionID,
                    feedback: feedback
                )
            }

        case .operatorText(let message):
            try await controlClient.sendApplicationData(
                ROBLegacyControllerPayload.operatorText(
                    message,
                    senderID: credential.controllerID
                )
            )
        }
    }

    public func openVideoDataStream(
        sessionID: UUID,
        stream: VideoStreamDescriptor
    ) async throws -> RobotVideoDataChannel {
        guard sessionID == activeSessionID,
              let clientID = videoClientIDBySubscriptionID[stream.id],
              let videoClient = videoClientsByID[clientID] else {
            throw VideoDataTransportError.inactiveSession
        }
        let channel = try await videoClient.openVideoDataStream(
            sessionID: sessionID,
            stream: stream
        )
        videoClientIDByDataChannelID[channel.id] = clientID
        return channel
    }

    public func closeVideoDataChannel(_ id: UUID) async {
        guard let clientID = videoClientIDByDataChannelID.removeValue(forKey: id),
              let client = videoClientsByID[clientID] else { return }
        await client.closeVideoDataChannel(id)
    }

    private func sendStoppedAndReleaseAuthority(reason: MotionInhibitReason) async throws {
        try await controlClient.sendApplicationData(
            ROBLegacyControllerPayload.stoppedSnapshot(
                senderID: credential.controllerID,
                reason: reason
            )
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

    private func startVideoEventMonitor(clientID: UUID, client: ROBVideoClient) {
        videoEventTasks[clientID]?.cancel()
        videoEventTasks[clientID] = Task { [weak self] in
            let events = await client.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handleVideoClientEvent(
                    event,
                    sourceID: clientID,
                    source: client
                )
            }
        }
    }

    private func connectVideoService(
        discoveryTimeout: Duration,
        controlSessionID: UUID
    ) async throws -> [CameraDescriptor] {
        guard videoClientsByID.isEmpty else {
            throw ROBCerebroTransportError.connectionFailed(
                "A Cerebro video connection is already active."
            )
        }
        let discoveredVideo = try await videoDiscovery.discover(
            credential: credential,
            timeout: discoveryTimeout
        )
        videoEndpoint = discoveredVideo.endpoint
        let client = ROBVideoClient(
            endpoint: discoveredVideo.endpoint,
            credential: credential,
            controlSessionID: controlSessionID
        )
        let clientID = UUID()
        videoClient = client
        videoClientsByID[clientID] = client
        startVideoEventMonitor(clientID: clientID, client: client)
        do {
            return try await client.connect()
        } catch {
            videoEventTasks.removeValue(forKey: clientID)?.cancel()
            videoClientsByID.removeValue(forKey: clientID)
            if videoClient === client { videoClient = nil }
            throw error
        }
    }

    private func acquireVideoClient(
        for subscriptionID: VideoSubscriptionID
    ) async throws -> (UUID, ROBVideoClient) {
        if videoClientIDBySubscriptionID[subscriptionID] != nil {
            throw VideoSubscriptionError.duplicateID(subscriptionID)
        }
        let occupied = Set(videoClientIDBySubscriptionID.values)
        if let available = videoClientsByID.first(where: { !occupied.contains($0.key) }) {
            videoClientIDBySubscriptionID[subscriptionID] = available.key
            return (available.key, available.value)
        }
        guard videoClientsByID.count < 3,
              let videoEndpoint,
              let activeSessionID else {
            throw ROBCerebroTransportError.videoUnavailable
        }

        let clientID = UUID()
        let client = ROBVideoClient(
            endpoint: videoEndpoint,
            credential: credential,
            controlSessionID: activeSessionID
        )
        videoClientsByID[clientID] = client
        videoClientIDBySubscriptionID[subscriptionID] = clientID
        startVideoEventMonitor(clientID: clientID, client: client)
        do {
            let cameras = try await client.connect()
            guard !cameras.isEmpty else { throw ROBCerebroTransportError.videoUnavailable }
            return (clientID, client)
        } catch {
            videoEventTasks.removeValue(forKey: clientID)?.cancel()
            videoClientsByID.removeValue(forKey: clientID)
            if videoClientIDBySubscriptionID[subscriptionID] == clientID {
                videoClientIDBySubscriptionID.removeValue(forKey: subscriptionID)
            }
            await client.disconnect()
            throw error
        }
    }

    private func videoClient(for subscriptionID: VideoSubscriptionID) -> ROBVideoClient? {
        guard let clientID = videoClientIDBySubscriptionID[subscriptionID] else { return nil }
        return videoClientsByID[clientID]
    }

    private func scheduleVideoReconnect() {
        guard activeSessionID != nil,
              !isDisconnecting,
              videoClientsByID.isEmpty,
              videoReconnectTask == nil else { return }
        let expectedSessionID = activeSessionID
        let delay = Self.videoReconnectDelay(afterFailedAttempts: videoReconnectAttempt)
        videoReconnectAttempt = min(videoReconnectAttempt + 1, 4)
        videoReconnectTask = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(for: delay)
            } catch {
                return
            }
            await self?.attemptVideoReconnect(expectedSessionID: expectedSessionID)
        }
    }

    private func attemptVideoReconnect(expectedSessionID: UUID?) async {
        videoReconnectTask = nil
        guard let expectedSessionID,
              activeSessionID == expectedSessionID,
              !isDisconnecting,
              videoClientsByID.isEmpty else { return }
        do {
            let cameras = try await connectVideoService(
                discoveryTimeout: .seconds(5),
                controlSessionID: expectedSessionID
            )
            guard !cameras.isEmpty else {
                throw ROBCerebroTransportError.videoUnavailable
            }
            guard await controlClient.liveSessionID() == expectedSessionID,
                  activeSessionID == expectedSessionID,
                  !isDisconnecting else {
                throw ROBCerebroTransportError.cancelled
            }
            videoUnavailableReason = nil
            videoReconnectAttempt = 0
            publish(.capabilitiesChanged(Self.capabilities(cameras: cameras)))
        } catch {
            videoUnavailableReason = Self.videoDiagnostic(from: error)
            await tearDownVideoConnection()
            if activeSessionID == expectedSessionID, !isDisconnecting {
                publish(.capabilitiesChanged(Self.capabilities(
                    cameras: [],
                    videoUnavailableReason: videoUnavailableReason
                )))
                scheduleVideoReconnect()
            }
        }
    }

    private func handleControlClientEvent(_ event: ROBControlClientEvent) async {
        switch event {
        case .disconnected(let error):
            guard activeSessionID != nil, !isDisconnecting else { return }
            activeSessionID = nil
            videoReconnectAttempt = 0
            videoReconnectTask?.cancel()
            videoReconnectTask = nil
            lastCommandSequence = 0
            let streams = activeVideoStreams
            activeVideoStreams.removeAll()
            videoClientIDBySubscriptionID.removeAll()
            videoClientIDByDataChannelID.removeAll()
            let clients = Array(videoClientsByID.values)
            for client in clients { await client.disconnect() }
            for id in streams {
                publish(.video(.ended(id: id, reason: "The bound control session ended.")))
            }
            publish(.disconnected(reason: error?.localizedDescription ?? "Cerebro disconnected."))

        case .applicationData(let data):
            if let authority = ROBLegacyControllerPayload.decodeControlAuthorityState(data) {
                publish(.safety(.armedChanged(
                    authority.isOwned(by: credential.controllerID)
                )))
                return
            }

            do {
                if let message = try RobotArmWireCodec.decode(data) {
                    switch message {
                    case .measuredState(let telemetry):
                        publish(.armTelemetry(telemetry))
                    case .authorityState(let state):
                        guard state.recipientID == credential.controllerID,
                            state.sessionID == activeSessionID
                        else { return }
                        publish(.armAuthorityState(state))
                    case .targetDisposition(let disposition):
                        guard disposition.recipientID == credential.controllerID,
                            disposition.sessionID == activeSessionID
                        else { return }
                        publish(.armTargetDisposition(disposition))
                    case .targetIntent, .authorityIntent, .holdIntent:
                        // Cerebro never originates controller intents.
                        break
                    }
                    return
                }
            } catch {
                // Application data also carries legacy keyed archives and
                // independent protocols. A malformed claimed arm message is
                // isolated from the safety-critical control connection.
                return
            }

            do {
                if let message = try RobotGripperWireCodec.decode(data) {
                    switch message {
                    case .state(let state):
                        publish(.gripperState(state))
                    case .commandDisposition(let disposition):
                        guard disposition.recipientID == credential.controllerID,
                            disposition.sessionID == activeSessionID
                        else { return }
                        publish(.gripperCommandDisposition(disposition))
                    case .commandIntent:
                        // Cerebro never originates controller intents.
                        break
                    }
                    return
                }
            } catch {
                // Malformed gripper-control frames are isolated from the
                // independent legacy and robot-action application protocols.
                return
            }

            do {
                guard let message = try RobotActionWireCodec.decodeArchive(data) else { return }
                let controllerID = credential.controllerID.uuidString.lowercased()
                guard message.recipientID == nil
                        || message.recipientID?.lowercased() == controllerID
                else { return }
                publish(.robotAction(message))
            } catch {
                // A malformed claimed robot-action envelope is isolated from
                // the control session and cannot reach another legacy parser.
                return
            }

        case .stateChanged, .lidarTelemetry:
            break
        }
    }

    private func handleVideoClientEvent(
        _ event: ROBVideoClientEvent,
        sourceID: UUID,
        source: ROBVideoClient
    ) async {
        guard videoClientsByID[sourceID] === source else { return }
        switch event {
        case .subscriptionResponse(let sessionID, let response):
            guard sessionID == activeSessionID else { return }
            switch response {
            case .accepted(let stream):
                videoClientIDBySubscriptionID[stream.id] = sourceID
                activeVideoStreams.insert(stream.id)
            case .rejected(let id, _):
                if videoClientIDBySubscriptionID[id] == sourceID {
                    videoClientIDBySubscriptionID.removeValue(forKey: id)
                }
            }
            publish(.video(.subscription(response)))

        case .streamEnded(let sessionID, let id, let reason):
            guard sessionID == activeSessionID else { return }
            activeVideoStreams.remove(id)
            if videoClientIDBySubscriptionID[id] == sourceID {
                videoClientIDBySubscriptionID.removeValue(forKey: id)
            }
            publish(.video(.ended(id: id, reason: reason)))

        case .disconnected(let reason):
            videoEventTasks.removeValue(forKey: sourceID)?.cancel()
            videoClientsByID.removeValue(forKey: sourceID)
            if videoClient === source {
                videoClient = videoClientsByID.values.first
            }
            let streams = Set(videoClientIDBySubscriptionID.compactMap { entry in
                entry.value == sourceID ? entry.key : nil
            })
            for id in streams {
                videoClientIDBySubscriptionID.removeValue(forKey: id)
                activeVideoStreams.remove(id)
                publish(.video(.ended(id: id, reason: reason)))
            }
            videoClientIDByDataChannelID = videoClientIDByDataChannelID.filter {
                $0.value != sourceID
            }
            if activeSessionID != nil, videoClientsByID.isEmpty {
                videoUnavailableReason = Self.videoDiagnostic(reason)
                publish(.capabilitiesChanged(Self.capabilities(
                    cameras: [],
                    videoUnavailableReason: videoUnavailableReason
                )))
                scheduleVideoReconnect()
            }
        }
    }

    private func tearDownConnections() async {
        videoReconnectAttempt = 0
        await tearDownVideoConnection()
        controlEventTask?.cancel()
        controlEventTask = nil
        await controlClient.disconnect()
    }

    private func tearDownVideoConnection() async {
        videoReconnectTask?.cancel()
        videoReconnectTask = nil
        let clients = Array(videoClientsByID.values)
        for task in videoEventTasks.values { task.cancel() }
        videoEventTasks.removeAll()
        self.videoClient = nil
        videoEndpoint = nil
        videoClientsByID.removeAll()
        videoClientIDBySubscriptionID.removeAll()
        videoClientIDByDataChannelID.removeAll()
        for client in clients { await client.disconnect() }
        await videoDiscovery.cancel()
        activeVideoStreams.removeAll()
    }

    private static func capabilities(
        cameras: [CameraDescriptor],
        videoUnavailableReason: String? = nil
    ) -> RobotCapabilities {
        RobotCapabilities(
            supportsMotionControl: true,
            // Network stop brakes and releases authority; the independently
            // wired physical emergency stop remains the definitive mechanism.
            supportsEmergencyStop: false,
            supportsArmControlExecution: true,
            cameras: cameras,
            videoUnavailableReason: videoUnavailableReason
        )
    }

    private static func videoDiagnostic(from error: Error) -> String {
        videoDiagnostic(error.localizedDescription)
    }

    private static func videoDiagnostic(_ detail: String) -> String {
        let singleLine = detail
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = singleLine.isEmpty ? "The video connection ended unexpectedly." : singleLine
        return String(bounded.prefix(320)) + (bounded.count > 320 ? "…" : "")
    }

    static func videoReconnectDelay(afterFailedAttempts attempts: Int) -> Duration {
        let seconds = [2, 4, 8, 16, 30][min(max(attempts, 0), 4)]
        return .seconds(seconds)
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
