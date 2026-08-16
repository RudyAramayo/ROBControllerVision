import Foundation
import Testing

@testable import ROBControlCore

@Suite("RobotSession supervised arm control")
struct RobotSessionArmControlTests {
    @Test("Authority, bounded target, and scene loss follow the fail-safe lifecycle")
    func authorityTargetAndSceneLossLifecycle() async throws {
        let transport = ArmControlTestTransport()
        let session = RobotSession(
            configuration: .init(
                commandInterval: .seconds(10),
                inputTimeout: .milliseconds(250),
                commandLeaseMilliseconds: 250
            )
        )
        await session.connect(using: transport)

        let requestID = try await session.requestArmAuthority(
            for: .left,
            durationMilliseconds: 60_000
        )
        let authorityRequest = try #require(
            await transport.envelope(withID: requestID)
        )
        guard case .armAuthority(let authorityCommand) = authorityRequest.command else {
            Issue.record("Expected an arm-authority command")
            await session.disconnect()
            return
        }
        #expect(authorityCommand.arm == .left)
        #expect(authorityCommand.operation == .acquire)
        #expect(authorityRequest.leaseMilliseconds == 60_000)

        let sessionID = transport.sessionID
        let controllerID = UUID()
        let authorityID = UUID()
        let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let granted = try #require(RobotArmAuthorityState(
            requestMessageID: requestID,
            recipientID: controllerID,
            sessionID: sessionID,
            arm: .left,
            state: .granted,
            authorityID: authorityID,
            expiresAtUnixMilliseconds: now + 60_000,
            detail: "Granted for deterministic session test.",
            baselinePositionsRadians: Array(repeating: 0, count: 7),
            baselineSequence: 40,
            modes: Array(repeating: 2, count: 7)
        ))
        await transport.publish(.armAuthorityState(granted))
        let measured = try #require(RobotArmMeasuredState(
            arm: .left,
            sequence: 41,
            sampledAtUnixMilliseconds: now,
            sampleAgeMilliseconds: 0,
            positionsRadians: Array(repeating: 0, count: 7),
            velocitiesRadiansPerSecond: Array(repeating: 0, count: 7),
            currents: Array(repeating: 0, count: 7),
            statuses: Array(repeating: 0, count: 7),
            modes: Array(repeating: 2, count: 7)
        ))
        await transport.publish(.armTelemetry(measured))

        try await waitUntil {
            let snapshot = await session.currentSnapshot()
            return snapshot.armTelemetry.leftControl.localControlIsArmed
                && snapshot.armTelemetry.left?.sequence == 41
        }

        var positions = Array(repeating: 0.0, count: 7)
        positions[2] = 0.06
        let target = try #require(RobotArmTargetIntent(
            arm: .left,
            source: .visionProJointUI,
            positionsRadians: positions,
            durationSeconds: 0.65
        ))
        let targetID = try await session.submitArmTargetSegment(target)
        let targetEnvelope = try #require(await transport.envelope(withID: targetID))
        guard case .armTarget(let targetCommand) = targetEnvelope.command else {
            Issue.record("Expected an arm-target command")
            await session.disconnect()
            return
        }
        #expect(targetCommand.authorityID == authorityID)
        #expect(targetCommand.deadManIsHeld)
        #expect(targetEnvelope.leaseMilliseconds == 1_000)

        let holdID = try await session.requestArmHold(
            for: .left,
            reason: "test_operator_released_dead_man"
        )
        let unconfirmedHold = try #require(RobotArmTargetDisposition(
            targetMessageID: holdID,
            recipientID: controllerID,
            sessionID: sessionID,
            arm: .left,
            receivedAtUnixMilliseconds: now + 1,
            disposition: .holdUnconfirmed,
            executionEligible: false,
            terminal: true,
            detail: "Gateway could not confirm measured hold."
        ))
        await transport.publish(.armTargetDisposition(unconfirmedHold))
        try await waitUntil {
            let snapshot = await session.currentSnapshot()
            return snapshot.armTelemetry.leftControl.pendingHoldMessageID == nil
                && !snapshot.armTelemetry.leftControl.localControlIsArmed
        }

        await session.setSceneActive(false)
        let holdCommands = await transport.armHoldCommands()
        #expect(Set(holdCommands.map(\.arm)) == Set(RobotArmSide.allCases))
        let inhibited = await session.currentSnapshot()
        #expect(!inhibited.armTelemetry.leftControl.localControlIsArmed)
        #expect(!inhibited.armTelemetry.rightControl.localControlIsArmed)
        await session.disconnect()
    }

    @Test("A late authority grant cannot restore a latch cleared by scene loss")
    func lateAuthorityGrantAfterSceneLossIsIgnored() async throws {
        let transport = ArmControlTestTransport()
        let session = RobotSession()
        await session.connect(using: transport)

        let requestID = try await session.requestArmAuthority(
            for: .right,
            durationMilliseconds: 60_000
        )
        await session.setSceneActive(false)

        let sessionID = transport.sessionID
        let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let lateGrant = try #require(RobotArmAuthorityState(
            requestMessageID: requestID,
            recipientID: UUID(),
            sessionID: sessionID,
            arm: .right,
            state: .granted,
            authorityID: UUID(),
            expiresAtUnixMilliseconds: now + 60_000,
            detail: "Late grant that must not restore local control.",
            baselinePositionsRadians: Array(repeating: 0, count: 7),
            baselineSequence: 9,
            modes: Array(repeating: 2, count: 7)
        ))
        await transport.publish(.armAuthorityState(lateGrant))
        await transport.publish(.telemetry(RobotTelemetry(
            batteryLevel: 0.37,
            pose: RobotPose(),
            linearVelocity: 0,
            angularVelocity: 0
        )))
        try await waitUntil {
            await session.currentSnapshot().telemetry?.batteryLevel == 0.37
        }

        let snapshot = await session.currentSnapshot()
        #expect(snapshot.armTelemetry.rightControl.pendingAuthorityRequestID == nil)
        #expect(!snapshot.armTelemetry.rightControl.localControlIsArmed)
        #expect(snapshot.armTelemetry.rightControl.authorityState == nil)
        await session.disconnect()
    }

    @Test("Left and right arm targets remain independently active")
    func simultaneousArmTargetsRemainIndependent() async throws {
        let transport = ArmControlTestTransport()
        let session = RobotSession(configuration: .init(commandInterval: .seconds(10)))
        await session.connect(using: transport)

        let leftRequestID = try await session.requestArmAuthority(
            for: .left,
            durationMilliseconds: 60_000
        )
        let rightRequestID = try await session.requestArmAuthority(
            for: .right,
            durationMilliseconds: 60_000
        )
        let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let controllerID = UUID()
        let grants: [(RobotArmSide, UUID)] = [
            (.left, leftRequestID),
            (.right, rightRequestID),
        ]
        for (arm, requestID) in grants {
            let authority = try #require(RobotArmAuthorityState(
                requestMessageID: requestID,
                recipientID: controllerID,
                sessionID: transport.sessionID,
                arm: arm,
                state: .granted,
                authorityID: UUID(),
                expiresAtUnixMilliseconds: now + 60_000,
                detail: "Granted for paired-arm test.",
                baselinePositionsRadians: Array(repeating: 0, count: 7),
                baselineSequence: arm == .left ? 50 : 60,
                modes: Array(repeating: 2, count: 7)
            ))
            let measured = try #require(RobotArmMeasuredState(
                arm: arm,
                sequence: arm == .left ? 51 : 61,
                sampledAtUnixMilliseconds: now,
                sampleAgeMilliseconds: 0,
                positionsRadians: Array(repeating: 0, count: 7),
                velocitiesRadiansPerSecond: Array(repeating: 0, count: 7),
                currents: Array(repeating: 0, count: 7),
                statuses: Array(repeating: 0, count: 7),
                modes: Array(repeating: 2, count: 7)
            ))
            await transport.publish(.armAuthorityState(authority))
            await transport.publish(.armTelemetry(measured))
        }
        try await waitUntil {
            let snapshot = await session.currentSnapshot()
            return snapshot.armTelemetry.leftControl.localControlIsArmed
                && snapshot.armTelemetry.rightControl.localControlIsArmed
        }

        var leftPositions = Array(repeating: 0.0, count: 7)
        leftPositions[1] = 0.06
        var rightPositions = Array(repeating: 0.0, count: 7)
        rightPositions[4] = -0.05
        let leftTarget = try #require(RobotArmTargetIntent(
            arm: .left,
            source: .visionProJointUI,
            positionsRadians: leftPositions,
            durationSeconds: 0.65
        ))
        let rightTarget = try #require(RobotArmTargetIntent(
            arm: .right,
            source: .visionProJointUI,
            positionsRadians: rightPositions,
            durationSeconds: 0.65
        ))
        async let submittedLeftID = session.submitArmTargetSegment(leftTarget)
        async let submittedRightID = session.submitArmTargetSegment(rightTarget)
        let (leftTargetID, rightTargetID) = try await (submittedLeftID, submittedRightID)

        let active = await session.currentSnapshot()
        #expect(active.armTelemetry.leftControl.activeTargetMessageID == leftTargetID)
        #expect(active.armTelemetry.rightControl.activeTargetMessageID == rightTargetID)
        let leftEnvelope = try #require(await transport.envelope(withID: leftTargetID))
        let rightEnvelope = try #require(await transport.envelope(withID: rightTargetID))
        #expect(leftEnvelope.sequence != rightEnvelope.sequence)

        _ = try await session.requestArmHold(for: .left, reason: "paired_test_left_release")
        let leftHeld = await session.currentSnapshot()
        #expect(leftHeld.armTelemetry.leftControl.activeTargetMessageID == nil)
        #expect(leftHeld.armTelemetry.rightControl.activeTargetMessageID == rightTargetID)
        #expect(leftHeld.armTelemetry.rightControl.localControlIsArmed)
        await session.disconnect()
    }

    @Test("Software emergency stop is sent before arm-hold cleanup")
    func emergencyStopPrecedesArmHolds() async throws {
        let transport = ArmControlTestTransport()
        let session = RobotSession(configuration: .init(commandInterval: .seconds(10)))
        await session.connect(using: transport)
        let startingCount = await transport.commands().count

        await session.emergencyStop()

        let commands = Array(await transport.commands().dropFirst(startingCount))
        let emergencyIndex = try #require(commands.firstIndex(where: {
            if case .emergencyStop = $0 { return true }
            return false
        }))
        let holdIndices = commands.indices.filter {
            if case .armHold = commands[$0] { return true }
            return false
        }
        #expect(holdIndices.count == RobotArmSide.allCases.count)
        #expect(holdIndices.allSatisfy { emergencyIndex < $0 })
        #expect(await session.currentSnapshot().safety.emergencyStopIsLatched)
        await session.disconnect()
    }

    @Test("Scene loss brakes base motion before arm-hold cleanup")
    func sceneLossStopPrecedesArmHolds() async throws {
        let transport = ArmControlTestTransport()
        let session = RobotSession(configuration: .init(commandInterval: .seconds(10)))
        await session.connect(using: transport)
        let startingCount = await transport.commands().count

        await session.setSceneActive(false)

        let commands = Array(await transport.commands().dropFirst(startingCount))
        let stopIndex = try #require(commands.firstIndex(where: {
            if case .stop = $0 { return true }
            return false
        }))
        let holdIndices = commands.indices.filter {
            if case .armHold = commands[$0] { return true }
            return false
        }
        #expect(holdIndices.count == RobotArmSide.allCases.count)
        #expect(holdIndices.allSatisfy { stopIndex < $0 })
        await session.disconnect()
    }

    @Test("A dropped gripper disposition times out and permits a safe retry")
    func gripperDispositionTimeoutRecoversPendingState() async throws {
        let transport = ArmControlTestTransport()
        let session = RobotSession(
            configuration: .init(
                commandInterval: .seconds(10),
                inputTimeout: .milliseconds(250),
                commandLeaseMilliseconds: 250,
                gripperDispositionTimeout: .milliseconds(100)
            )
        )
        await session.connect(using: transport)

        let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let calibrated = try #require(RobotGripperState(
            arm: .left,
            sequence: 1,
            sampledAtUnixMilliseconds: now,
            calibrationState: .commandAcceptedUnverified,
            calibrationVerified: false,
            feedbackAvailable: false,
            commandInFlight: false,
            lastAction: nil,
            lastForce: nil,
            detail: "Calibration dispatch accepted; result is not measured."
        ))
        await transport.publish(.gripperState(calibrated))
        try await waitUntil {
            await session.currentSnapshot().gripperTelemetry.left?.sequence == 1
        }

        let hold = try #require(
            RobotGripperCommandIntent(arm: .left, action: .hold, force: 5)
        )
        let holdID = try await session.submitGripperCommand(hold, deadManIsHeld: true)
        #expect(
            await session.currentSnapshot().gripperTelemetry.leftControl
                .pendingCommandMessageID == holdID
        )

        try await waitUntil {
            await session.currentSnapshot().gripperTelemetry.leftControl
                .pendingCommandMessageID == nil
        }
        #expect(
            await session.currentSnapshot().gripperTelemetry.leftControl
                .lastTimedOutCommandMessageID == holdID
        )

        let release = try #require(
            RobotGripperCommandIntent(arm: .left, action: .release, force: 5)
        )
        let releaseID = try await session.submitGripperCommand(release, deadManIsHeld: true)
        #expect(await transport.envelope(withID: releaseID) != nil)
        #expect(
            await session.currentSnapshot().gripperTelemetry.leftControl
                .lastTimedOutCommandMessageID == nil
        )
        await session.disconnect()
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
        Issue.record("Timed out waiting for the RobotSession snapshot")
    }
}

private actor ArmControlTestTransport: RobotTransport {
    nonisolated let descriptor = RobotEndpointDescriptor(
        name: "Arm Control Test Cerebro",
        serviceType: "_robctl._udp",
        transport: .quic
    )
    let sessionID = UUID()

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
            capabilities: RobotCapabilities(supportsArmControlExecution: true)
        )
    }

    func disconnect() {
        continuation?.finish()
        continuation = nil
    }

    func send(_ envelope: RobotCommandEnvelope) throws {
        guard envelope.sessionID == sessionID else {
            throw RobotTransportError.invalidState("Stale test session")
        }
        envelopes.append(envelope)
        continuation?.yield(.commandAcknowledged(envelope.id))
    }

    func publish(_ event: RobotEvent) {
        continuation?.yield(event)
    }

    func envelope(withID id: UUID) -> RobotCommandEnvelope? {
        envelopes.first(where: { $0.id == id })
    }

    func armHoldCommands() -> [RobotArmHoldCommand] {
        envelopes.compactMap { envelope in
            guard case .armHold(let command) = envelope.command else { return nil }
            return command
        }
    }

    func commands() -> [RobotCommand] {
        envelopes.map(\.command)
    }
}
