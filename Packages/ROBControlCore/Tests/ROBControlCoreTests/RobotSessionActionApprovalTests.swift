import Foundation
import Testing

@testable import ROBControlCore

@Suite("RobotSession supervised action approval")
struct RobotSessionActionApprovalTests {
    private let controllerID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    @Test("Operator acceptance remains pending until Cerebro reports measured completion")
    func acceptedGestureLifecycle() async throws {
        let transport = RobotActionTestTransport()
        let session = RobotSession(configuration: .init(commandInterval: .seconds(10)))
        await session.configureRobotActionController(senderID: controllerID)
        await session.connect(using: transport)
        try await session.setRobotActionApprovalsEnabled(true)

        let request = try makeGestureRequest()
        await transport.publish(.robotAction(request))
        try await waitUntil {
            await session.currentSnapshot().robotActions.pendingRequest?.callID
                == request.callID
        }
        #expect(await transport.sentActionStates().contains(.pending))

        try await session.respondToPendingRobotAction(
            .accepted,
            detail: "Operator approved beside the droid."
        )
        #expect(await transport.sentActionStates().contains(.accepted))
        #expect(await session.currentSnapshot().robotActions.pendingRequest != nil)

        let executing = try RobotActionMessage(
            kind: .actionStatus,
            callID: request.callID,
            senderID: request.senderID,
            recipientID: controllerID,
            state: .executing,
            detail: "Amber accepted the leased gesture."
        )
        await transport.publish(.robotAction(executing))
        try await waitUntil {
            await session.currentSnapshot().robotActions.lastStatus?.state == .executing
        }

        let completed = try RobotActionMessage(
            kind: .actionStatus,
            callID: request.callID,
            senderID: request.senderID,
            recipientID: controllerID,
            state: .completed,
            detail: "Measured pose and velocity settled."
        )
        await transport.publish(.robotAction(completed))
        try await waitUntil {
            let snapshot = await session.currentSnapshot().robotActions
            return snapshot.pendingRequest == nil && snapshot.lastStatus?.state == .completed
        }
        await session.disconnect()
    }

    @Test("Scene loss cancels a request and withdraws controller availability")
    func sceneLossCancelsAndDisables() async throws {
        let transport = RobotActionTestTransport()
        let session = RobotSession(configuration: .init(commandInterval: .seconds(10)))
        await session.configureRobotActionController(senderID: controllerID)
        await session.connect(using: transport)
        try await session.setRobotActionApprovalsEnabled(true)
        await transport.publish(.robotAction(try makeGestureRequest()))
        try await waitUntil {
            await session.currentSnapshot().robotActions.pendingRequest != nil
        }

        await session.setSceneActive(false)
        let actions = await transport.sentActions()
        #expect(actions.contains(where: { $0.kind == .actionStatus && $0.state == .cancelled }))
        #expect(actions.contains(where: {
            $0.kind == .controllerHello && $0.acceptsActions == false
        }))
        let snapshot = await session.currentSnapshot()
        #expect(!snapshot.robotActions.isEnabled)
        #expect(snapshot.robotActions.pendingRequest == nil)
        await session.disconnect()
    }

    @Test("Requests fail closed while approvals are disabled")
    func disabledRejectsRequest() async throws {
        let transport = RobotActionTestTransport()
        let session = RobotSession(configuration: .init(commandInterval: .seconds(10)))
        await session.configureRobotActionController(senderID: controllerID)
        await session.connect(using: transport)
        await transport.publish(.robotAction(try makeGestureRequest()))
        try await waitUntil {
            await transport.sentActionStates().contains(.rejected)
        }
        #expect(await session.currentSnapshot().robotActions.pendingRequest == nil)
        await session.disconnect()
    }

    private func makeGestureRequest() throws -> RobotActionMessage {
        let now = RobotActionMessage.nowMilliseconds
        return try RobotActionMessage(
            kind: .actionRequest,
            callID: "gesture-call-1",
            senderID: "cerebro-main",
            recipientID: controllerID,
            sentAtMilliseconds: now,
            expiresAtMilliseconds: now + 30_000,
            action: .playGesture,
            arguments: ["gesture": .string("friendly_wave")],
            state: .pending
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await predicate() { return }
            try await clock.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for robot-action state")
    }
}

private actor RobotActionTestTransport: RobotTransport {
    nonisolated let descriptor = RobotEndpointDescriptor(
        name: "Robot Action Test Cerebro",
        serviceType: "_robctl._udp",
        transport: .quic
    )
    private let sessionID = UUID()
    private var continuation: AsyncStream<RobotEvent>.Continuation?
    private var envelopes: [RobotCommandEnvelope] = []

    func events() -> AsyncStream<RobotEvent> {
        let pair = AsyncStream<RobotEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        continuation = pair.continuation
        return pair.stream
    }

    func connect() -> RobotHandshake {
        RobotHandshake(
            sessionID: sessionID,
            robotName: descriptor.name,
            capabilities: RobotCapabilities()
        )
    }

    func disconnect() {
        continuation?.finish()
        continuation = nil
    }

    func send(_ envelope: RobotCommandEnvelope) throws {
        guard envelope.sessionID == sessionID else { throw RobotTransportError.notConnected }
        envelopes.append(envelope)
        continuation?.yield(.commandAcknowledged(envelope.id))
    }

    func publish(_ event: RobotEvent) {
        continuation?.yield(event)
    }

    func sentActions() -> [RobotActionMessage] {
        envelopes.compactMap { envelope in
            guard case .robotAction(let message) = envelope.command else { return nil }
            return message
        }
    }

    func sentActionStates() -> [RobotActionState] {
        sentActions().compactMap { message in
            message.kind == .actionStatus ? message.state : nil
        }
    }
}
