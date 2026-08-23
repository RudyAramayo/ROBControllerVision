import Foundation
import Testing

@testable import ROBControlCore

@Suite("RobotSession operator text")
struct RobotSessionOperatorTextTests {
    @Test("Command and puppet text preserve their explicit mode")
    func sendsBothOperatorTextModes() async throws {
        let transport = OperatorTextTestTransport()
        let session = RobotSession(configuration: .init(commandInterval: .seconds(10)))
        await session.connect(using: transport)

        try await session.sendOperatorText("  Navigate to the kitchen  ", mode: .command)
        try await session.sendOperatorText("  Hello from ROB  ", mode: .puppetSpeech)

        let messages = await transport.operatorTextMessages()
        #expect(
            messages == [
                OperatorTextMessage(text: "Navigate to the kitchen", mode: .command),
                OperatorTextMessage(text: "Hello from ROB", mode: .puppetSpeech),
            ]
        )
        await session.disconnect()
    }
}

private actor OperatorTextTestTransport: RobotTransport {
    nonisolated let descriptor = RobotEndpointDescriptor(
        name: "Operator Text Test Cerebro",
        serviceType: "_robctl._udp",
        transport: .quic
    )

    private let sessionID = UUID()
    private var continuation: AsyncStream<RobotEvent>.Continuation?
    private var envelopes: [RobotCommandEnvelope] = []

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
        envelopes.append(envelope)
    }

    func operatorTextMessages() -> [OperatorTextMessage] {
        envelopes.compactMap { envelope in
            guard case .operatorText(let message) = envelope.command else { return nil }
            return message
        }
    }
}
