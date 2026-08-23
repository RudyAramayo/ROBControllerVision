import Foundation
import Testing

@testable import ROBControlCore

@Suite("RobotSession dynamic capabilities")
struct RobotSessionCapabilityTests {
    @Test("A late video service updates camera capabilities without reconnecting control")
    func lateCameraCapabilityUpdate() async throws {
        let transport = CapabilityTestTransport()
        let session = RobotSession(configuration: .init(commandInterval: .seconds(10)))
        await session.connect(using: transport)
        #expect(await session.currentSnapshot().connection.handshake?.capabilities.cameras.isEmpty == true)

        let camera = CameraDescriptor(
            id: CameraID(rawValue: "front"),
            name: "Cerebro Front Camera",
            supportedCodecs: [.h264],
            maximumWidth: 960,
            maximumHeight: 540,
            maximumFramesPerSecond: 20
        )
        await transport.publish(.capabilitiesChanged(RobotCapabilities(cameras: [camera])))

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if await session.currentSnapshot().connection.handshake?.capabilities.cameras == [camera] {
                break
            }
            try await clock.sleep(for: .milliseconds(5))
        }
        #expect(await session.currentSnapshot().connection.handshake?.capabilities.cameras == [camera])
        #expect(await session.currentSnapshot().connection.isReady)
        await session.disconnect()
    }
}

private actor CapabilityTestTransport: RobotTransport {
    nonisolated let descriptor = RobotEndpointDescriptor(
        name: "Capability Test Cerebro",
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
            capabilities: RobotCapabilities(cameras: [])
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
