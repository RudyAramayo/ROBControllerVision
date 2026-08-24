import Foundation
import Testing

@testable import ROBControlCore

@Suite("RobotSession motion authority confirmation")
struct RobotSessionMotionAuthorityTests {
    @Test("Sending an authority request does not locally grant control")
    func requestRemainsPendingUntilRobotConfirmation() async throws {
        let transport = MotionAuthorityTestTransport()
        let session = RobotSession(
            configuration: .init(
                commandInterval: .seconds(10),
                motionAuthorityRequestTimeout: .seconds(1)
            )
        )
        await session.connect(using: transport)
        await session.setArmed(true)

        var snapshot = await session.currentSnapshot()
        #expect(snapshot.safety.controlAuthority == .requesting)
        #expect(!snapshot.safety.isArmed)

        await transport.publish(.safety(.armedChanged(true)))
        try await waitUntil {
            await session.currentSnapshot().safety.controlAuthority == .granted
        }

        snapshot = await session.currentSnapshot()
        #expect(snapshot.safety.controlAuthority == .granted)
        #expect(snapshot.safety.isArmed)
        await session.disconnect()
    }

    @Test("A robot response naming another owner remains not granted")
    func robotCanDeclineAuthority() async throws {
        let transport = MotionAuthorityTestTransport()
        let session = RobotSession(
            configuration: .init(
                commandInterval: .seconds(10),
                motionAuthorityRequestTimeout: .seconds(1)
            )
        )
        await session.connect(using: transport)
        await session.setArmed(true)
        await transport.publish(.safety(.armedChanged(false)))
        try await waitUntil {
            await session.currentSnapshot().safety.controlAuthority == .notGranted
        }

        let snapshot = await session.currentSnapshot()
        #expect(snapshot.safety.controlAuthority == .notGranted)
        #expect(!snapshot.safety.isArmed)
        await session.disconnect()
    }

    @Test("An unanswered request returns to an unconfirmed state")
    func authorityRequestTimesOutWithoutGrantingControl() async throws {
        let transport = MotionAuthorityTestTransport()
        let session = RobotSession(
            configuration: .init(
                commandInterval: .seconds(10),
                motionAuthorityRequestTimeout: .milliseconds(30)
            )
        )
        await session.connect(using: transport)
        await session.setArmed(true)
        try await waitUntil {
            await session.currentSnapshot().safety.controlAuthority == .unknown
        }

        let snapshot = await session.currentSnapshot()
        #expect(snapshot.safety.controlAuthority == .unknown)
        #expect(!snapshot.safety.isArmed)
        await session.disconnect()
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await clock.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for the motion-authority state")
    }
}

private actor MotionAuthorityTestTransport: RobotTransport {
    nonisolated let descriptor = RobotEndpointDescriptor(
        name: "Motion Authority Test ROB",
        serviceType: "_robctl._udp",
        transport: .quic
    )
    private let sessionID = UUID()
    private var continuation: AsyncStream<RobotEvent>.Continuation?

    func events() -> AsyncStream<RobotEvent> {
        let pair = AsyncStream<RobotEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
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
    }

    func publish(_ event: RobotEvent) {
        continuation?.yield(event)
    }
}
