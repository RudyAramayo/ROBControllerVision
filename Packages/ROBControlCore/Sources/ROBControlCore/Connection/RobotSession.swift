import Foundation

public actor RobotSession {
    private struct VideoDataChannelOwnership: Sendable {
        let transport: any RobotVideoDataTransport
        let sessionID: UUID
        let subscriptionID: VideoSubscriptionID
    }

    public struct Configuration: Sendable {
        public var commandInterval: Duration
        public var inputTimeout: Duration
        public var commandLeaseMilliseconds: UInt32

        public init(
            commandInterval: Duration = .milliseconds(100),
            inputTimeout: Duration = .milliseconds(250),
            commandLeaseMilliseconds: UInt32 = 250
        ) {
            self.commandInterval = commandInterval
            self.inputTimeout = inputTimeout
            self.commandLeaseMilliseconds = commandLeaseMilliseconds
        }
    }

    private let configuration: Configuration
    private var snapshot = RobotSessionSnapshot()
    private var subscribers: [UUID: AsyncStream<RobotSessionSnapshot>.Continuation] = [:]
    private var transport: (any RobotTransport)?
    private var connectionAttemptID: UUID?
    private var eventTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var disconnectOperationID: UUID?
    private var disconnectTask: Task<Void, Never>?
    private var pendingVideoSubscriptions:
        [VideoSubscriptionID: CheckedContinuation<VideoSubscriptionResponse, Error>] = [:]
    private var videoTimeoutTasks: [VideoSubscriptionID: Task<Void, Never>] = [:]
    private var abandonedVideoSubscriptions: Set<VideoSubscriptionID> = []
    private var videoDataChannelOwners: [UUID: VideoDataChannelOwnership] = [:]
    private var deadMan: DeadManController
    private var commandSequence: UInt64 = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.deadMan = DeadManController(
            configuration: .init(inputTimeout: configuration.inputTimeout)
        )
    }

    deinit {
        eventTask?.cancel()
        commandTask?.cancel()
        disconnectTask?.cancel()
        for task in videoTimeoutTasks.values {
            task.cancel()
        }
        for continuation in pendingVideoSubscriptions.values {
            continuation.resume(throwing: CancellationError())
        }
        for continuation in subscribers.values {
            continuation.finish()
        }
    }

    public func updates() -> AsyncStream<RobotSessionSnapshot> {
        let subscriberID = UUID()
        let pair = AsyncStream<RobotSessionSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        subscribers[subscriberID] = pair.continuation
        pair.continuation.yield(snapshot)
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(subscriberID) }
        }
        return pair.stream
    }

    public func currentSnapshot() -> RobotSessionSnapshot {
        snapshot
    }

    public func connect(using newTransport: any RobotTransport) async {
        guard snapshot.connection.phase == .disconnected || snapshot.connection.phase == .failed else {
            return
        }

        if let cleanupTask {
            await cleanupTask.value
            self.cleanupTask = nil
        }
        guard snapshot.connection.phase == .disconnected || snapshot.connection.phase == .failed else {
            return
        }

        if snapshot.connection.phase == .failed, let previousTransport = transport {
            eventTask?.cancel()
            commandTask?.cancel()
            eventTask = nil
            commandTask = nil
            await previousTransport.disconnect()
            transport = nil
        }
        guard snapshot.connection.phase == .disconnected || snapshot.connection.phase == .failed else {
            return
        }

        let attemptID = UUID()
        connectionAttemptID = attemptID
        transport = newTransport
        deadMan.setArmed(false)
        deadMan.invalidateInput(reason: .disconnected)
        commandSequence = 0
        snapshot.connection = RobotConnectionState(
            phase: .connecting,
            endpoint: newTransport.descriptor
        )
        publish()

        let events = await newTransport.events()
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handle(event, attemptID: attemptID)
            }
        }

        snapshot.connection.phase = .handshaking
        publish()

        do {
            let handshake = try await newTransport.connect()
            guard connectionAttemptID == attemptID else {
                await newTransport.disconnect()
                return
            }
            guard handshake.protocolVersion == RobotCommandEnvelope.currentProtocolVersion else {
                await newTransport.disconnect()
                fail(
                    ConnectionFailure(
                        code: .handshakeRejected,
                        message: "Robot protocol version \(handshake.protocolVersion) is unsupported.",
                        isRecoverable: false
                    )
                )
                return
            }

            snapshot.connection = RobotConnectionState(
                phase: .connected,
                endpoint: newTransport.descriptor,
                handshake: handshake
            )
            deadMan.setArmed(false)
            if handshake.safetyState.emergencyStopIsLatched {
                deadMan.emergencyStop()
            }
            deadMan.invalidateInput(reason: .deadManReleased)
            synchronizeSafetyState(
                inhibitReason: deadMan.emergencyStopIsLatched
                    ? .emergencyStop
                    : .operatorDisarmed
            )
            startCommandLoop(attemptID: attemptID)
            publish()
        } catch is CancellationError {
            guard connectionAttemptID == attemptID else { return }
            fail(
                ConnectionFailure(
                    code: .cancelled,
                    message: "Connection attempt cancelled."
                )
            )
        } catch {
            guard connectionAttemptID == attemptID else { return }
            fail(
                ConnectionFailure(
                    code: .transportUnavailable,
                    message: error.localizedDescription
                )
            )
        }
    }

    public func disconnect() async {
        if let disconnectTask, let disconnectOperationID {
            await disconnectTask.value
            completeDisconnect(operationID: disconnectOperationID)
            return
        }
        guard snapshot.connection.phase != .disconnected else { return }

        let activeTransport = transport
        let operationID = UUID()
        disconnectOperationID = operationID
        connectionAttemptID = nil
        snapshot.connection.phase = .disconnecting
        deadMan.setArmed(false)
        synchronizeSafetyState(inhibitReason: .disconnected)
        var stopEnvelope: RobotCommandEnvelope?
        if let sessionID = snapshot.connection.handshake?.sessionID {
            commandSequence &+= 1
            stopEnvelope = RobotCommandEnvelope(
                sessionID: sessionID,
                sequence: commandSequence,
                leaseMilliseconds: configuration.commandLeaseMilliseconds,
                command: .stop(.userRequested)
            )
        }

        eventTask?.cancel()
        commandTask?.cancel()
        eventTask = nil
        commandTask = nil
        let dataChannels = videoDataChannelOwners
        videoDataChannelOwners.removeAll()
        transport = nil
        cancelPendingVideoSubscriptions(with: RobotTransportError.notConnected)
        snapshot.telemetry = nil
        snapshot.videoStreams = []
        synchronizeSafetyState(inhibitReason: .disconnected)
        publish()

        let task = Task {
            if let stopEnvelope {
                try? await activeTransport?.send(stopEnvelope)
            }
            for (channelID, ownership) in dataChannels {
                await ownership.transport.closeVideoDataChannel(channelID)
            }
            await activeTransport?.disconnect()
        }
        disconnectTask = task
        await task.value
        completeDisconnect(operationID: operationID)
    }

    private func completeDisconnect(operationID: UUID) {
        guard disconnectOperationID == operationID else { return }
        disconnectTask = nil
        disconnectOperationID = nil
        snapshot.connection = .disconnected
        synchronizeSafetyState(inhibitReason: .disconnected)
        publish()
    }

    public func setArmed(_ armed: Bool) async {
        guard snapshot.connection.isReady else { return }

        if !armed {
            deadMan.setArmed(false)
            deadMan.invalidateInput(reason: .operatorDisarmed)
            synchronizeSafetyState(inhibitReason: .operatorDisarmed)
            publish()
        }

        do {
            try await send(.setArmed(armed))
            if armed {
                deadMan.setArmed(true)
                deadMan.invalidateInput(reason: .deadManReleased)
                synchronizeSafetyState(inhibitReason: .deadManReleased)
                publish()
            }
        } catch {
            handleSendFailure(error)
        }
    }

    public func updateOperatorInput(_ sample: OperatorControlSample) {
        deadMan.update(sample)
    }

    public func invalidateInput(reason: MotionInhibitReason) async {
        deadMan.invalidateInput(reason: reason)
        synchronizeSafetyState(inhibitReason: reason)
        publish()

        guard snapshot.connection.isReady else { return }
        do {
            try await send(.stop(reason))
        } catch {
            handleSendFailure(error)
        }
    }

    public func setSceneActive(_ active: Bool) async {
        deadMan.setSceneActive(active)
        if !active {
            synchronizeSafetyState(inhibitReason: .sceneInactive)
            publish()
            if snapshot.connection.isReady {
                do {
                    try await send(.stop(.sceneInactive))
                } catch {
                    handleSendFailure(error)
                }
            }
        }
    }

    public func emergencyStop() async {
        deadMan.emergencyStop()
        synchronizeSafetyState(inhibitReason: .emergencyStop)
        publish()

        guard snapshot.connection.isReady else { return }
        do {
            try await send(.emergencyStop)
        } catch {
            handleSendFailure(error)
        }
    }

    public func resetEmergencyStop() async {
        guard snapshot.connection.isReady else { return }
        do {
            try await send(.resetEmergencyStop)
            deadMan.resetEmergencyStop()
            synchronizeSafetyState(inhibitReason: .operatorDisarmed)
            publish()
        } catch {
            handleSendFailure(error)
        }
    }

    public func subscribeVideo(
        _ request: VideoSubscriptionRequest
    ) async throws -> VideoSubscriptionResponse {
        guard snapshot.connection.isReady else { throw RobotTransportError.notConnected }
        guard pendingVideoSubscriptions[request.id] == nil,
            !abandonedVideoSubscriptions.contains(request.id),
            !snapshot.videoStreams.contains(where: { $0.id == request.id })
        else {
            throw VideoSubscriptionError.duplicateID(request.id)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingVideoSubscriptions[request.id] = continuation
                videoTimeoutTasks[request.id]?.cancel()
                videoTimeoutTasks[request.id] = Task { [weak self] in
                    do {
                        try await ContinuousClock().sleep(for: .seconds(2))
                    } catch {
                        return
                    }
                    await self?.timeOutVideoSubscription(request.id)
                }
                Task { [weak self] in
                    await self?.beginVideoSubscription(request)
                }
            }
        } onCancel: {
            Task { await self.cancelVideoSubscription(request.id) }
        }
    }

    public func unsubscribeVideo(_ id: VideoSubscriptionID) async throws {
        guard snapshot.connection.isReady else { throw RobotTransportError.notConnected }
        try await send(.video(.unsubscribe(VideoUnsubscribeRequest(id: id))))
    }

    public func sendVideoFeedback(_ feedback: VideoReceiverFeedback) async throws {
        guard snapshot.connection.isReady else { throw RobotTransportError.notConnected }
        try await send(.video(.feedback(feedback)))
    }

    public func openVideoDataStream(
        for id: VideoSubscriptionID
    ) async throws -> RobotVideoDataChannel {
        guard snapshot.connection.isReady,
            let sessionID = snapshot.connection.handshake?.sessionID,
            let attemptID = connectionAttemptID
        else {
            throw RobotTransportError.notConnected
        }
        guard let stream = snapshot.videoStreams.first(where: { $0.id == id }) else {
            throw VideoDataTransportError.subscriptionNotFound(id)
        }
        guard let videoTransport = transport as? any RobotVideoDataTransport else {
            throw VideoDataTransportError.unavailable
        }
        let channel = try await videoTransport.openVideoDataStream(
            sessionID: sessionID,
            stream: stream
        )
        guard channel.sessionID == sessionID, channel.descriptor == stream else {
            await videoTransport.closeVideoDataChannel(channel.id)
            throw VideoDataTransportError.channelMetadataMismatch
        }
        guard connectionAttemptID == attemptID,
            snapshot.connection.isReady,
            snapshot.connection.handshake?.sessionID == sessionID,
            snapshot.videoStreams.first(where: { $0.id == id }) == stream
        else {
            await videoTransport.closeVideoDataChannel(channel.id)
            throw VideoDataTransportError.inactiveSession
        }
        videoDataChannelOwners[channel.id] = VideoDataChannelOwnership(
            transport: videoTransport,
            sessionID: sessionID,
            subscriptionID: id
        )
        return channel
    }

    public func closeVideoDataChannel(_ id: UUID) async {
        guard let ownership = videoDataChannelOwners.removeValue(forKey: id) else { return }
        await ownership.transport.closeVideoDataChannel(id)
    }

    private func startCommandLoop(attemptID: UUID) {
        commandTask?.cancel()
        let interval = configuration.commandInterval
        commandTask = Task { [weak self] in
            let timer = ContinuousClock()
            while !Task.isCancelled {
                await self?.sendControlTick(attemptID: attemptID)
                do {
                    try await timer.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    private func sendControlTick(attemptID: UUID) async {
        guard connectionAttemptID == attemptID, snapshot.connection.isReady else { return }

        let decision = deadMan.evaluate(connectionIsReady: true)
        switch decision {
        case .drive(let motion):
            synchronizeSafetyState(inhibitReason: nil)
            do {
                try await send(.drive(motion))
            } catch {
                handleSendFailure(error)
            }

        case .stop(let reason):
            synchronizeSafetyState(inhibitReason: reason)
            do {
                if reason == .emergencyStop {
                    try await send(.emergencyStop)
                } else {
                    try await send(.stop(reason))
                }
            } catch {
                handleSendFailure(error)
            }
        }
        publish()
    }

    private func send(_ command: RobotCommand) async throws {
        guard let transport, let sessionID = snapshot.connection.handshake?.sessionID else {
            throw RobotTransportError.notConnected
        }
        commandSequence &+= 1
        let envelope = RobotCommandEnvelope(
            sessionID: sessionID,
            sequence: commandSequence,
            leaseMilliseconds: configuration.commandLeaseMilliseconds,
            command: command
        )
        try await transport.send(envelope)
        snapshot.safety.lastCommandSequence = commandSequence
    }

    private func handle(_ event: RobotEvent, attemptID: UUID) async {
        guard connectionAttemptID == attemptID else { return }

        switch event {
        case .connected:
            break

        case .disconnected(let reason):
            fail(
                ConnectionFailure(
                    code: .transportUnavailable,
                    message: reason
                ),
                inhibitReason: .disconnected
            )

        case .telemetry(let telemetry):
            snapshot.telemetry = telemetry
            publish()

        case .commandAcknowledged:
            break

        case .safety(let event):
            apply(event)
            publish()

        case .video(let event):
            await apply(event)
            publish()
        }
    }

    private func apply(_ event: RobotSafetyEvent) {
        switch event {
        case .motionStopped(let reason):
            if reason == .robotWatchdog || reason == .emergencyStop {
                deadMan.setArmed(false)
                deadMan.invalidateInput(reason: reason)
            }
            snapshot.safety.inhibitReason = reason
        case .armedChanged(let armed):
            if !armed {
                deadMan.setArmed(false)
            }
            snapshot.safety.isArmed = armed && deadMan.isArmed
        case .emergencyStopChanged(let latched):
            if latched {
                deadMan.emergencyStop()
            }
            snapshot.safety.emergencyStopIsLatched = latched || deadMan.emergencyStopIsLatched
        }
    }

    private func apply(_ event: VideoEvent) async {
        switch event {
        case .subscription(let response):
            let id = response.subscriptionID
            videoTimeoutTasks.removeValue(forKey: id)?.cancel()
            let continuation = pendingVideoSubscriptions.removeValue(forKey: id)
            let wasAbandoned = abandonedVideoSubscriptions.remove(id) != nil
            guard !wasAbandoned, let continuation else {
                if case .accepted = response {
                    try? await send(.video(.unsubscribe(VideoUnsubscribeRequest(id: id))))
                }
                return
            }
            continuation.resume(returning: response)
            if case .accepted(let stream) = response {
                snapshot.videoStreams.removeAll(where: { $0.id == stream.id })
                snapshot.videoStreams.append(stream)
            }
        case .ended(let id, _):
            snapshot.videoStreams.removeAll(where: { $0.id == id })
            let sessionID = snapshot.connection.handshake?.sessionID
            let channelIDs = videoDataChannelOwners.compactMap { channelID, ownership in
                ownership.subscriptionID == id && ownership.sessionID == sessionID
                    ? channelID
                    : nil
            }
            let ownerships: [(UUID, VideoDataChannelOwnership)] = channelIDs.compactMap {
                channelID in
                guard let ownership = videoDataChannelOwners.removeValue(forKey: channelID) else {
                    return nil
                }
                return (channelID, ownership)
            }
            for (channelID, ownership) in ownerships {
                await ownership.transport.closeVideoDataChannel(channelID)
            }
        }
    }

    private func synchronizeSafetyState(inhibitReason: MotionInhibitReason?) {
        snapshot.safety.isArmed = deadMan.isArmed
        snapshot.safety.emergencyStopIsLatched = deadMan.emergencyStopIsLatched
        snapshot.safety.inhibitReason = inhibitReason
    }

    private func handleSendFailure(_ error: Error) {
        if error is CancellationError { return }

        if let transportError = error as? RobotTransportError {
            switch transportError {
            case .commandExpired, .invalidState:
                deadMan.setArmed(false)
                deadMan.invalidateInput(reason: .transportFailure)
                synchronizeSafetyState(inhibitReason: .transportFailure)
                publish()
                return
            case .alreadyConnected, .notConnected, .staleCommand:
                break
            }
        }

        fail(
            ConnectionFailure(
                code: .transportUnavailable,
                message: error.localizedDescription
            )
        )
    }

    private func fail(
        _ failure: ConnectionFailure,
        inhibitReason: MotionInhibitReason = .transportFailure
    ) {
        eventTask?.cancel()
        commandTask?.cancel()
        eventTask = nil
        commandTask = nil
        connectionAttemptID = nil
        deadMan.setArmed(false)
        deadMan.invalidateInput(reason: inhibitReason)
        let failedTransport = transport
        let failedDataChannels = videoDataChannelOwners
        videoDataChannelOwners.removeAll()
        transport = nil
        cleanupTask = Task {
            for (channelID, ownership) in failedDataChannels {
                await ownership.transport.closeVideoDataChannel(channelID)
            }
            await failedTransport?.disconnect()
        }
        snapshot.connection = RobotConnectionState(
            phase: .failed,
            endpoint: snapshot.connection.endpoint,
            failure: failure
        )
        snapshot.telemetry = nil
        snapshot.videoStreams = []
        cancelPendingVideoSubscriptions(with: failure)
        synchronizeSafetyState(
            inhibitReason: deadMan.emergencyStopIsLatched ? .emergencyStop : inhibitReason
        )
        publish()
    }

    private func timeOutVideoSubscription(_ id: VideoSubscriptionID) {
        videoTimeoutTasks.removeValue(forKey: id)?.cancel()
        guard let continuation = pendingVideoSubscriptions.removeValue(forKey: id) else { return }
        abandonedVideoSubscriptions.insert(id)
        continuation.resume(throwing: VideoSubscriptionError.timedOut)
    }

    private func beginVideoSubscription(_ request: VideoSubscriptionRequest) async {
        guard pendingVideoSubscriptions[request.id] != nil else {
            abandonedVideoSubscriptions.remove(request.id)
            return
        }
        do {
            try await send(.video(.subscribe(request)))
        } catch {
            videoTimeoutTasks.removeValue(forKey: request.id)?.cancel()
            pendingVideoSubscriptions.removeValue(forKey: request.id)?.resume(throwing: error)
            abandonedVideoSubscriptions.remove(request.id)
            handleSendFailure(error)
        }
    }

    private func cancelVideoSubscription(_ id: VideoSubscriptionID) {
        videoTimeoutTasks.removeValue(forKey: id)?.cancel()
        guard let continuation = pendingVideoSubscriptions.removeValue(forKey: id) else { return }
        abandonedVideoSubscriptions.insert(id)
        continuation.resume(throwing: VideoSubscriptionError.cancelled)
    }

    private func cancelPendingVideoSubscriptions(with error: any Error) {
        for task in videoTimeoutTasks.values {
            task.cancel()
        }
        videoTimeoutTasks.removeAll()
        let continuations = pendingVideoSubscriptions.values
        pendingVideoSubscriptions.removeAll()
        abandonedVideoSubscriptions.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func publish() {
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
