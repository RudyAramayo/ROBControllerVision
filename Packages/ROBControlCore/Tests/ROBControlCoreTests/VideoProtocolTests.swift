import Foundation
import Testing

@testable import ROBControlCore

@Suite("Video subscription protocol")
struct VideoProtocolTests {
    @Test("Subscription messages round-trip through Codable")
    func subscriptionRoundTrip() throws {
        let message = VideoControlMessage.subscribe(
            VideoSubscriptionRequest(
                cameraID: CameraID(rawValue: "front"),
                preferredCodecs: [.h264, .jpeg],
                constraints: VideoConstraints(
                    maximumWidth: 1_280,
                    maximumHeight: 720,
                    maximumFramesPerSecond: 30,
                    maximumBitrate: 2_500_000
                ),
                delivery: .quicDatagrams
            )
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(VideoControlMessage.self, from: data)

        #expect(decoded == message)
    }

    @Test("Zero-valued constraints are rejected before negotiation")
    func invalidConstraints() {
        let constraints = VideoConstraints(
            maximumWidth: 0,
            maximumHeight: 720,
            maximumFramesPerSecond: 30,
            maximumBitrate: 2_500_000
        )

        #expect(!constraints.isValid)
    }

    @Test("Control envelopes use an explicit tagged wire schema")
    func explicitControlEnvelopeSchema() throws {
        let envelope = RobotCommandEnvelope(
            sessionID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            sequence: 42,
            issuedAt: Date(timeIntervalSince1970: 1_000),
            leaseMilliseconds: 250,
            command: .drive(MotionVector(linear: 0.5, angular: -0.25))
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let command = try #require(object["command"] as? [String: Any])

        #expect(command["type"] as? String == "drive")
        #expect(object["issuedAtUnixMilliseconds"] as? Int == 1_000_000)
        #expect(object["issuedAt"] == nil)
        #expect(
            try JSONDecoder().decode(RobotCommandEnvelope.self, from: data) == envelope
        )
    }

    @Test("Decoded non-finite motion values fail closed to zero")
    func nonFiniteMotionFailsClosed() throws {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        let data = Data(#"{"linear":"NaN","angular":"Infinity"}"#.utf8)
        let motion = try decoder.decode(MotionVector.self, from: data)

        #expect(motion == .stopped)
    }
}
