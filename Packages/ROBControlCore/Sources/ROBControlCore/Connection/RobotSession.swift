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
        public var gripperDispositionTimeout: Duration

        public init(
            commandInterval: Duration = .milliseconds(100),
            inputTimeout: Duration = .milliseconds(250),
            commandLeaseMilliseconds: UInt32 = 250,
            gripperDispositionTimeout: Duration = .seconds(2)
        ) {
            self.commandInterval = commandInterval
            self.inputTimeout = inputTimeout
            self.commandLeaseMilliseconds = commandLeaseMilliseconds
            self.gripperDispositionTimeout = gripperDispositionTimeout
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
    private var gripperTimeoutTasks: [RobotArmSide: Task<Void, Never>] = [:]
    private var abandonedVideoSubscriptions: Set<VideoSubscriptionID> = []
    private var videoDataChannelOwners: [UUID: VideoDataChannelOwnership] = [:]
    private var deadMan: DeadManController
    private var commandSequence: UInt64 = 0
    private var sceneIsActive = true
    private var robotActionHelloSentAtUptime: TimeInterval?

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
        for task in gripperTimeoutTasks.values {
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
        cancelGripperTimeouts()
        robotActionHelloSentAtUptime = nil
        snapshot.robotActions.isEnabled = false
        snapshot.robotActions.pendingRequest = nil
        snapshot.robotActions.lastStatus = nil
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
        deadMan.setArmed(false)
        synchronizeSafetyState(inhibitReason: .disconnected)
        publish()
        if snapshot.connection.isReady {
            // Brake base motion before auxiliary action cancellation and arm
            // holds so teardown traffic cannot delay the primary stop.
            _ = try? await send(.stop(.userRequested))
        }
        await disableRobotActionApprovals(reason: "Vision controller disconnected")
        await requestPriorityArmHoldsIgnoringFailure(reason: "session_disconnect")

        let operationID = UUID()
        disconnectOperationID = operationID
        connectionAttemptID = nil
        snapshot.connection.phase = .disconnecting
        synchronizeSafetyState(inhibitReason: .disconnected)

        eventTask?.cancel()
        commandTask?.cancel()
        eventTask = nil
        commandTask = nil
        let dataChannels = videoDataChannelOwners
        videoDataChannelOwners.removeAll()
        transport = nil
        cancelPendingVideoSubscriptions(with: RobotTransportError.notConnected)
        snapshot.telemetry = nil
        snapshot.armTelemetry = RobotArmTelemetrySnapshot()
        cancelGripperTimeouts()
        snapshot.gripperTelemetry = RobotGripperTelemetrySnapshot()
        snapshot.robotActions.isEnabled = false
        snapshot.robotActions.pendingRequest = nil
        snapshot.videoStreams = []
        synchronizeSafetyState(inhibitReason: .disconnected)
        publish()

        let task = Task {
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
            await requestPriorityArmHoldsIgnoringFailure(reason: "drive_control_disarmed")
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
        sceneIsActive = active
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
            await disableRobotActionApprovals(reason: "Vision app became inactive")
            await requestPriorityArmHoldsIgnoringFailure(reason: "vision_scene_inactive")
        }
    }

    public func emergencyStop() async {
        deadMan.emergencyStop()
        synchronizeSafetyState(inhibitReason: .emergencyStop)
        publish()

        if snapshot.connection.isReady {
            do {
                // The primary stop must lead every auxiliary cancellation or
                // hold request so those network round trips cannot delay it.
                try await send(.emergencyStop)
            } catch {
                handleSendFailure(error)
            }
        }
        await disableRobotActionApprovals(reason: "Vision software emergency stop")
        await requestPriorityArmHoldsIgnoringFailure(reason: "software_emergency_stop")
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

    public func sendOperatorText(_ text: String, mode: OperatorTextMode) async throws {
        guard snapshot.connection.isReady else { throw RobotTransportError.notConnected }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1_024 else {
            throw RobotTransportError.invalidState("Operator text must contain 1 through 1,024 characters.")
        }
        try await send(.operatorText(OperatorTextMessage(text: trimmed, mode: mode)))
    }

    /// Installs the authenticated controller identity used by Cerebro's
    /// application-level action ledger. Changing it always returns approvals
    /// to off, so a pairing replacement cannot inherit an older grant.
    public func configureRobotActionController(senderID: String?) {
        let normalized = senderID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let bounded = normalized.flatMap { value in
            value.isEmpty || value.count > 128 ? nil : value
        }
        guard snapshot.robotActions.controllerID != bounded else { return }
        snapshot.robotActions = RobotActionApprovalSnapshot(controllerID: bounded)
        robotActionHelloSentAtUptime = nil
        publish()
    }

    /// Enables or disables Cerebro action proposals for this foreground
    /// session. Availability is refreshed every second while enabled because
    /// Cerebro deliberately expires stale approval consoles.
    public func setRobotActionApprovalsEnabled(_ enabled: Bool) async throws {
        if !enabled {
            await disableRobotActionApprovals(reason: "Operator disabled action approvals")
            return
        }
        guard snapshot.connection.isReady else { throw RobotTransportError.notConnected }
        guard sceneIsActive, !snapshot.safety.emergencyStopIsLatched else {
            throw RobotTransportError.invalidState(
                "Action approvals require an active Vision scene with the software stop released."
            )
        }
        guard snapshot.robotActions.controllerID != nil else {
            throw RobotTransportError.invalidState(
                "No authenticated controller identity is configured for action approvals."
            )
        }
        snapshot.robotActions.isEnabled = true
        snapshot.robotActions.pendingRequest = nil
        snapshot.robotActions.lastStatus = nil
        publish()
        do {
            try await sendRobotActionHello(force: true)
        } catch {
            snapshot.robotActions.isEnabled = false
            robotActionHelloSentAtUptime = nil
            publish()
            throw error
        }
    }

    /// Records the operator's explicit disposition for the currently visible
    /// immutable request. Accepting a named Amber gesture authorizes Cerebro to
    /// execute it; Cerebro, not Vision, subsequently owns measured completion.
    public func respondToPendingRobotAction(
        _ requestedState: RobotActionState,
        detail: String
    ) async throws {
        guard snapshot.connection.isReady else { throw RobotTransportError.notConnected }
        guard let request = snapshot.robotActions.pendingRequest,
              let controllerID = snapshot.robotActions.controllerID else {
            throw RobotTransportError.invalidState("There is no pending robot action.")
        }
        guard [.accepted, .rejected, .cancelled, .failed, .completed]
            .contains(requestedState) else {
            throw RobotTransportError.invalidState("That action state is not an operator response.")
        }
        if requestedState == .accepted, !snapshot.robotActions.isEnabled {
            throw RobotTransportError.invalidState("Action approvals are disabled.")
        }
        if request.action == .playGesture,
           requestedState == .completed || requestedState == .failed {
            throw RobotTransportError.invalidState(
                "Cerebro owns measured completion for an approved Amber gesture."
            )
        }

        let state: RobotActionState = request.isExpired && requestedState == .accepted
            ? .expired : requestedState
        let boundedDetail = String(detail.prefix(2_048))
        let status = try RobotActionMessage.status(
            for: request,
            state: state,
            detail: state == .expired
                ? "Approval deadline elapsed before the operator accepted it."
                : boundedDetail,
            senderID: controllerID
        )
        try await send(.robotAction(status))
        snapshot.robotActions.lastStatus = status
        if state.isTerminal {
            snapshot.robotActions.pendingRequest = nil
        }
        publish()
    }

    /// Requests a server-owned, time-limited authority for one Amber arm.
    /// Cerebro remains authoritative and may reject this request even when the
    /// local Vision latch is clear.
    @discardableResult
    public func requestArmAuthority(
        for arm: RobotArmSide,
        durationMilliseconds: UInt32 = 300_000
    ) async throws -> UUID {
        guard snapshot.connection.isReady else { throw RobotTransportError.notConnected }
        guard snapshot.connection.handshake?.capabilities.supportsArmControlExecution == true else {
            throw RobotTransportError.invalidState(
                "This endpoint does not advertise physical Amber arm execution."
            )
        }
        guard !snapshot.safety.emergencyStopIsLatched, sceneIsActive else {
            throw RobotTransportError.invalidState(
                "Arm authority requires an active scene with the software stop released."
            )
        }
        guard (60_000 ... 600_000).contains(durationMilliseconds) else {
            throw RobotTransportError.invalidState("Arm authority duration is out of bounds.")
        }
        if deadMan.isArmed {
            await setArmed(false)
        }

        let requestID = UUID()
        snapshot.armTelemetry.updateControlState(for: arm) { control in
            control.localControlIsArmed = false
            control.pendingAuthorityRequestID = requestID
            control.activeTargetMessageID = nil
            control.activeTargetSentAtUptime = nil
        }
        publish()
        do {
            _ = try await send(
                .armAuthority(RobotArmAuthorityCommand(arm: arm, operation: .acquire)),
                leaseMilliseconds: durationMilliseconds,
                id: requestID
            )
            return requestID
        } catch {
            snapshot.armTelemetry.updateControlState(for: arm) { control in
                if control.pendingAuthorityRequestID == requestID {
                    control.pendingAuthorityRequestID = nil
                }
            }
            publish()
            throw error
        }
    }

    public func releaseArmAuthority(for arm: RobotArmSide) async throws {
        guard snapshot.connection.isReady else { throw RobotTransportError.notConnected }
        _ = try? await requestArmHold(for: arm, reason: "operator_released_authority")
        let requestID = UUID()
        snapshot.armTelemetry.updateControlState(for: arm) { control in
            control.localControlIsArmed = false
            control.pendingAuthorityRequestID = requestID
            control.activeTargetMessageID = nil
            control.activeTargetSentAtUptime = nil
        }
        publish()
        do {
            _ = try await send(
                .armAuthority(RobotArmAuthorityCommand(arm: arm, operation: .release)),
                leaseMilliseconds: 1_000,
                id: requestID
            )
        } catch {
            snapshot.armTelemetry.updateControlState(for: arm) { control in
                if control.pendingAuthorityRequestID == requestID {
                    control.pendingAuthorityRequestID = nil
                }
            }
            publish()
            throw error
        }
    }

    /// Sends one bounded 0.65-second segment while the operator's hold is
    /// currently asserted. Completion remains driven by measured feedback.
    @discardableResult
    public func submitArmTargetSegment(
        _ target: RobotArmTargetIntent
    ) async throws -> UUID {
        guard snapshot.connection.isReady else { throw RobotTransportError.notConnected }
        guard sceneIsActive, !snapshot.safety.emergencyStopIsLatched else {
            throw RobotTransportError.invalidState("Arm motion is inhibited by app safety state.")
        }
        let arm = target.arm
        let control = snapshot.armTelemetry.controlState(for: arm)
        guard control.localControlIsArmed,
            control.activeTargetMessageID == nil,
            let authority = control.authorityState,
            authority.state == .granted,
            authority.sessionID == snapshot.connection.handshake?.sessionID,
            authority.expiresAt.timeIntervalSinceNow > 0,
            let authorityID = authority.authorityID
        else {
            throw RobotTransportError.invalidState("Arm control authority is not active.")
        }
        guard let measured = snapshot.armTelemetry.measuredState(for: arm),
            let age = snapshot.armTelemetry.effectiveSampleAgeMilliseconds(for: arm),
            age <= 250,
            measured.modes.count == RobotArmTargetIntent.jointCount,
            measured.modes.allSatisfy({ $0 == 2 })
        else {
            throw RobotTransportError.invalidState(
                "Fresh measured telemetry with all joints in position mode is required."
            )
        }
        let deltas = zip(measured.positionsRadians, target.positionsRadians).map {
            abs($0 - $1)
        }
        guard deltas.allSatisfy({ $0 <= 0.080_001 }),
            deltas.allSatisfy({ $0 / target.durationSeconds <= 0.20 })
        else {
            throw RobotTransportError.invalidState(
                "The requested segment exceeds the 0.08-radian or 0.20-radian/second limit."
            )
        }

        let messageID = UUID()
        snapshot.armTelemetry.updateControlState(for: arm) { state in
            state.activeTargetMessageID = messageID
            state.activeTargetSentAtUptime = ProcessInfo.processInfo.systemUptime
        }
        publish()
        do {
            _ = try await send(
                .armTarget(
                    RobotArmTargetCommand(
                        target: target,
                        authorityID: authorityID,
                        deadManIsHeld: true
                    )
                ),
                leaseMilliseconds: 1_000,
                id: messageID
            )
            return messageID
        } catch {
            snapshot.armTelemetry.updateControlState(for: arm) { state in
                if state.activeTargetMessageID == messageID {
                    state.activeTargetMessageID = nil
                    state.activeTargetSentAtUptime = nil
                }
            }
            publish()
            throw error
        }
    }

    @discardableResult
    public func requestArmHold(
        for arm: RobotArmSide,
        reason: String
    ) async throws -> UUID {
        guard snapshot.connection.isReady else { throw RobotTransportError.notConnected }
        let authorityID = snapshot.armTelemetry.controlState(for: arm).authorityState?.authorityID
        guard let command = RobotArmHoldCommand(
            arm: arm,
            authorityID: authorityID,
            reason: reason
        ) else {
            throw RobotTransportError.invalidState("Arm hold reason is invalid.")
        }
        let messageID = UUID()
        snapshot.armTelemetry.updateControlState(for: arm) { state in
            state.activeTargetMessageID = nil
            state.activeTargetSentAtUptime = nil
            state.pendingHoldMessageID = messageID
        }
        publish()
        do {
            _ = try await send(
                .armHold(command),
                leaseMilliseconds: 1_000,
                id: messageID
            )
            return messageID
        } catch {
            snapshot.armTelemetry.updateControlState(for: arm) { state in
                if state.pendingHoldMessageID == messageID {
                    state.pendingHoldMessageID = nil
                }
            }
            publish()
            throw error
        }
    }

    public func requestPriorityArmHolds(reason: String) async {
        await requestPriorityArmHoldsIgnoringFailure(reason: reason)
    }

    /// Sends one authenticated, leased gripper edge. Calibration is performed
    /// locally in Cerebro; Vision can operate a gripper only after Cerebro has
    /// reported that Amber accepted calibration during the current gateway
    /// session. Amber v1 reports dispatch, not measured opening or force.
    @discardableResult
    public func submitGripperCommand(
        _ intent: RobotGripperCommandIntent,
        deadManIsHeld: Bool
    ) async throws -> UUID {
        guard snapshot.connection.isReady else { throw RobotTransportError.notConnected }
        guard sceneIsActive, !snapshot.safety.emergencyStopIsLatched else {
            throw RobotTransportError.invalidState(
                "Gripper control is inhibited by the app safety state."
            )
        }
        guard deadManIsHeld else {
            throw RobotTransportError.invalidState(
                "Hold both controller grip buttons before operating a gripper."
            )
        }
        guard snapshot.gripperTelemetry.state(for: intent.arm)?.calibrationState
                == .commandAcceptedUnverified else {
            throw RobotTransportError.invalidState(
                "Calibrate this gripper in Cerebro after the current power-up first."
            )
        }
        guard snapshot.gripperTelemetry.control(for: intent.arm)
                .pendingCommandMessageID == nil else {
            throw RobotTransportError.invalidState(
                "A gripper command is already awaiting its Amber acknowledgement."
            )
        }

        let messageID = UUID()
        snapshot.gripperTelemetry.updateControl(for: intent.arm) { state in
            state.pendingCommandMessageID = messageID
            state.lastTimedOutCommandMessageID = nil
        }
        scheduleGripperTimeout(for: intent.arm, messageID: messageID)
        publish()
        do {
            _ = try await send(
                .gripper(
                    RobotGripperCommand(
                        intent: intent,
                        deadManIsHeld: deadManIsHeld
                    )
                ),
                leaseMilliseconds: 750,
                id: messageID
            )
            return messageID
        } catch {
            gripperTimeoutTasks.removeValue(forKey: intent.arm)?.cancel()
            snapshot.gripperTelemetry.updateControl(for: intent.arm) { state in
                if state.pendingCommandMessageID == messageID {
                    state.pendingCommandMessageID = nil
                }
            }
            publish()
            throw error
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

    private func requestPriorityArmHoldsIgnoringFailure(reason: String) async {
        for arm in RobotArmSide.allCases {
            snapshot.armTelemetry.updateControlState(for: arm) { state in
                state.localControlIsArmed = false
                state.pendingAuthorityRequestID = nil
                state.activeTargetMessageID = nil
                state.activeTargetSentAtUptime = nil
            }
        }
        publish()
        guard snapshot.connection.isReady else { return }
        for arm in RobotArmSide.allCases {
            _ = try? await requestArmHold(for: arm, reason: reason)
        }
    }

    private func disableRobotActionApprovals(reason: String) async {
        let wasEnabled = snapshot.robotActions.isEnabled
        snapshot.robotActions.isEnabled = false

        if snapshot.connection.isReady,
           let request = snapshot.robotActions.pendingRequest,
           let controllerID = snapshot.robotActions.controllerID,
           let cancelled = try? RobotActionMessage.status(
                for: request,
                state: .cancelled,
                detail: String(reason.prefix(2_048)),
                senderID: controllerID
           ) {
            _ = try? await send(.robotAction(cancelled))
            snapshot.robotActions.lastStatus = cancelled
        }
        snapshot.robotActions.pendingRequest = nil

        if snapshot.connection.isReady,
           snapshot.robotActions.controllerID != nil,
           wasEnabled {
            try? await sendRobotActionHello(force: true)
        }
        robotActionHelloSentAtUptime = nil
        publish()
    }

    private func sendRobotActionHello(force: Bool) async throws {
        guard let controllerID = snapshot.robotActions.controllerID else {
            throw RobotTransportError.invalidState(
                "No authenticated controller identity is configured for action approvals."
            )
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        if !force {
            guard snapshot.robotActions.isEnabled else { return }
            if let last = robotActionHelloSentAtUptime, uptime - last < 1.0 { return }
        }
        let hello = try RobotActionMessage.controllerHello(
            senderID: controllerID,
            acceptsActions: snapshot.robotActions.isEnabled
        )
        try await send(.robotAction(hello))
        robotActionHelloSentAtUptime = uptime
    }

    private func handleRobotAction(_ message: RobotActionMessage) async {
        guard let controllerID = snapshot.robotActions.controllerID else { return }

        switch message.kind {
        case .controllerHello:
            // Cerebro is the proposal source, not another approval console.
            return

        case .actionRequest:
            if message.isExpired {
                await sendRobotActionStatus(
                    for: message,
                    state: .expired,
                    detail: "The action request arrived after its approval deadline.",
                    controllerID: controllerID
                )
                return
            }
            guard snapshot.robotActions.isEnabled else {
                await sendRobotActionStatus(
                    for: message,
                    state: .rejected,
                    detail: "Vision operator action approvals are disabled.",
                    controllerID: controllerID
                )
                return
            }
            if let current = snapshot.robotActions.pendingRequest {
                if current.callID == message.callID {
                    if let last = snapshot.robotActions.lastStatus,
                       last.callID == message.callID {
                        _ = try? await send(.robotAction(last))
                    } else {
                        await sendRobotActionStatus(
                            for: current,
                            state: .pending,
                            detail: "Waiting for the supervising Vision operator.",
                            controllerID: controllerID,
                            retainRequest: true
                        )
                    }
                } else {
                    await sendRobotActionStatus(
                        for: message,
                        state: .rejected,
                        detail: "Another physical action is already awaiting disposition.",
                        controllerID: controllerID
                    )
                }
                return
            }

            snapshot.robotActions.pendingRequest = message
            snapshot.robotActions.lastStatus = nil
            await sendRobotActionStatus(
                for: message,
                state: .pending,
                detail: "Waiting for the supervising Vision operator.",
                controllerID: controllerID,
                retainRequest: true
            )

        case .actionStatus:
            guard let current = snapshot.robotActions.pendingRequest,
                  current.callID == message.callID,
                  current.senderID == message.senderID else { return }
            snapshot.robotActions.lastStatus = message
            if message.state.isTerminal {
                snapshot.robotActions.pendingRequest = nil
            }
            publish()

        case .actionCancel:
            guard let current = snapshot.robotActions.pendingRequest,
                  current.callID == message.callID,
                  current.senderID == message.senderID else { return }
            await sendRobotActionStatus(
                for: current,
                state: .cancelled,
                detail: message.detail ?? "Cerebro cancelled the action request.",
                controllerID: controllerID
            )
        }
    }

    private func sendRobotActionStatus(
        for request: RobotActionMessage,
        state: RobotActionState,
        detail: String,
        controllerID: String,
        retainRequest: Bool = false
    ) async {
        guard let status = try? RobotActionMessage.status(
            for: request,
            state: state,
            detail: String(detail.prefix(2_048)),
            senderID: controllerID
        ) else { return }
        do {
            try await send(.robotAction(status))
        } catch {
            handleSendFailure(error)
            return
        }
        let isCurrentRequest = snapshot.robotActions.pendingRequest?.callID == request.callID
        if retainRequest || isCurrentRequest || snapshot.robotActions.pendingRequest == nil {
            snapshot.robotActions.lastStatus = status
        }
        if state.isTerminal && !retainRequest && isCurrentRequest {
            snapshot.robotActions.pendingRequest = nil
        }
        publish()
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

        if snapshot.robotActions.isEnabled {
            do {
                try await sendRobotActionHello(force: false)
            } catch {
                handleSendFailure(error)
                return
            }
        }

        let decision = deadMan.evaluate(connectionIsReady: true)
        switch decision {
        case .drive(let motion, let camera, let grippers, let torso, let controllerPoses):
            synchronizeSafetyState(inhibitReason: nil)
            do {
                try await send(.drive(motion, camera, grippers, torso, controllerPoses))
            } catch {
                handleSendFailure(error)
            }

        case .stop(let reason, let controllerPoses):
            synchronizeSafetyState(inhibitReason: reason)
            do {
                if reason == .emergencyStop {
                    try await send(.emergencyStop)
                } else {
                    try await send(.stop(reason, controllerPoses))
                }
            } catch {
                handleSendFailure(error)
            }
        }
        publish()
    }

    @discardableResult
    private func send(
        _ command: RobotCommand,
        leaseMilliseconds: UInt32? = nil,
        id: UUID = UUID()
    ) async throws -> UUID {
        guard let transport, let sessionID = snapshot.connection.handshake?.sessionID else {
            throw RobotTransportError.notConnected
        }
        commandSequence &+= 1
        let envelope = RobotCommandEnvelope(
            id: id,
            sessionID: sessionID,
            sequence: commandSequence,
            leaseMilliseconds: leaseMilliseconds ?? configuration.commandLeaseMilliseconds,
            command: command
        )
        try await transport.send(envelope)
        snapshot.safety.lastCommandSequence = commandSequence
        return id
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

        case .armTelemetry(let telemetry):
            snapshot.armTelemetry.apply(telemetry)
            publish()

        case .armAuthorityState(let authority):
            guard authority.sessionID == snapshot.connection.handshake?.sessionID else { return }
            let current = snapshot.armTelemetry.controlState(for: authority.arm)
            if authority.state == .granted {
                guard current.pendingAuthorityRequestID == authority.requestMessageID else { return }
            } else if let pending = current.pendingAuthorityRequestID,
                pending != authority.requestMessageID,
                current.authorityState?.authorityID != authority.authorityID
            {
                return
            }
            snapshot.armTelemetry.updateControlState(for: authority.arm) { state in
                state.authorityState = authority
                if state.pendingAuthorityRequestID == authority.requestMessageID {
                    state.pendingAuthorityRequestID = nil
                }
                state.localControlIsArmed = authority.state == .granted
                if authority.state != .granted {
                    state.activeTargetMessageID = nil
                    state.activeTargetSentAtUptime = nil
                }
            }
            publish()

        case .armTargetDisposition(let disposition):
            guard disposition.sessionID == snapshot.connection.handshake?.sessionID else { return }
            let control = snapshot.armTelemetry.controlState(for: disposition.arm)
            guard control.activeTargetMessageID == disposition.targetMessageID
                || control.pendingHoldMessageID == disposition.targetMessageID
            else { return }
            snapshot.armTelemetry.lastTargetDisposition = disposition
            snapshot.armTelemetry.updateControlState(for: disposition.arm) { state in
                state.lastDisposition = disposition
                if disposition.terminal,
                    state.activeTargetMessageID == disposition.targetMessageID
                {
                    state.activeTargetMessageID = nil
                    state.activeTargetSentAtUptime = nil
                }
                if disposition.terminal,
                    state.pendingHoldMessageID == disposition.targetMessageID
                {
                    state.pendingHoldMessageID = nil
                }
                switch disposition.disposition {
                case .rejectedAuthorityDisabled, .rejectedExpired,
                    .rejectedIdentityMismatch, .rejectedSessionInactive,
                    .holdUnconfirmed, .failed:
                    state.localControlIsArmed = false
                default:
                    break
                }
            }
            publish()

        case .gripperState(let state):
            snapshot.gripperTelemetry.apply(state)
            publish()

        case .gripperCommandDisposition(let disposition):
            guard disposition.sessionID == snapshot.connection.handshake?.sessionID else { return }
            let control = snapshot.gripperTelemetry.control(for: disposition.arm)
            guard control.pendingCommandMessageID == disposition.requestMessageID else { return }
            snapshot.gripperTelemetry.updateControl(for: disposition.arm) { state in
                state.lastDisposition = disposition
                if disposition.terminal {
                    state.pendingCommandMessageID = nil
                }
            }
            if disposition.terminal {
                gripperTimeoutTasks.removeValue(forKey: disposition.arm)?.cancel()
            }
            publish()

        case .robotAction(let message):
            await handleRobotAction(message)

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
                    _ = try? await send(.video(.unsubscribe(VideoUnsubscribeRequest(id: id))))
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
        snapshot.armTelemetry = RobotArmTelemetrySnapshot()
        cancelGripperTimeouts()
        snapshot.gripperTelemetry = RobotGripperTelemetrySnapshot()
        snapshot.robotActions.isEnabled = false
        snapshot.robotActions.pendingRequest = nil
        robotActionHelloSentAtUptime = nil
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

    private func scheduleGripperTimeout(for arm: RobotArmSide, messageID: UUID) {
        gripperTimeoutTasks.removeValue(forKey: arm)?.cancel()
        let timeout = configuration.gripperDispositionTimeout
        gripperTimeoutTasks[arm] = Task { [weak self] in
            let clock = ContinuousClock()
            do { try await clock.sleep(for: timeout) } catch { return }
            await self?.timeOutGripperCommand(for: arm, messageID: messageID)
        }
    }

    private func timeOutGripperCommand(for arm: RobotArmSide, messageID: UUID) {
        guard snapshot.gripperTelemetry.control(for: arm).pendingCommandMessageID == messageID
        else { return }
        gripperTimeoutTasks.removeValue(forKey: arm)
        snapshot.gripperTelemetry.updateControl(for: arm) { state in
            state.pendingCommandMessageID = nil
            state.lastTimedOutCommandMessageID = messageID
        }
        publish()
    }

    private func cancelGripperTimeouts() {
        let tasks = Array(gripperTimeoutTasks.values)
        gripperTimeoutTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
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
            // Video is an independently authenticated media service. A failed subscription must
            // not tear down the safety-critical control connection.
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
