import Foundation
import Testing

@testable import ROBControlCore

@Suite("Amber arm preview transport")
struct ArmControlProtocolTests {
    private let messageID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let senderID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let sessionID = UUID(uuidString: "12345678-1234-5678-9abc-def012345678")!
    private let now: Int64 = 1_725_000_000_000

    @Test("Cerebro measured-state JSON decodes into bounded seven-joint feedback")
    func measuredStateGoldenFixture() throws {
        let json = """
            {
              "protocol":"rob-arm-control/1",
              "schema_version":1,
              "type":"measured_state",
              "message_id":"11111111-2222-3333-4444-555555555555",
              "arm":"left",
              "sequence":42,
              "sampled_at_unix_ms":1725000000000,
              "sample_age_ms":2.5,
              "positions_rad":[0.1,0.2,0.3,0.4,0.5,0.6,0.7],
              "velocities_rad_s":[0,0,0,0,0,0,0],
              "currents":[1,2,3,4,5,6,7],
              "statuses":[1,1,1,1,1,1,1]
            }
            """
        guard case .measuredState(let state) = try RobotArmWireCodec.decode(Data(json.utf8)) else {
            Issue.record("Expected a measured-state message")
            return
        }
        #expect(state.messageID == messageID)
        #expect(state.arm == .left)
        #expect(state.sequence == 42)
        #expect(state.positionsRadians.count == 7)
        #expect(state.sampleAgeMilliseconds == 2.5)

        var snapshot = RobotArmTelemetrySnapshot()
        snapshot.apply(state)
        #expect(snapshot.left == state)
        #expect(snapshot.right == nil)
    }

    @Test("Vision target intent uses the authenticated session and explicit bounds")
    func targetIntentGoldenFixture() throws {
        let target = try #require(
            RobotArmTargetIntent(
                arm: .right,
                source: .visionProSpatial,
                positionsRadians: [0, 0.25, -0.5, 0.75, -1, 1.25, 0.1],
                durationSeconds: 0.8
            )
        )
        let data = try RobotArmWireCodec.encodeTargetIntent(
            target,
            messageID: messageID,
            senderID: senderID,
            sessionID: sessionID,
            sequence: 9,
            issuedAtUnixMilliseconds: now,
            leaseMilliseconds: 250,
            nowUnixMilliseconds: now
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["protocol"] as? String == "rob-arm-control/1")
        #expect(object["type"] as? String == "target_intent")
        #expect(object["sender_id"] as? String == senderID.uuidString)
        #expect(object["session_id"] as? String == sessionID.uuidString)
        #expect(object["execution_eligible"] == nil)

        guard case .targetIntent(let decoded) = try RobotArmWireCodec.decode(
            data,
            nowUnixMilliseconds: now
        ) else {
            Issue.record("Expected target intent")
            return
        }
        #expect(decoded.messageID == messageID)
        #expect(decoded.senderID == senderID)
        #expect(decoded.sessionID == sessionID)
        #expect(decoded.target == target)
    }

    @Test("Invalid targets fail before reaching transport")
    func invalidTargetsFailClosed() throws {
        #expect(
            RobotArmTargetIntent(
                arm: .left,
                source: .visionProJointUI,
                positionsRadians: [0, 0, 0],
                durationSeconds: 1
            ) == nil
        )
        let upperBounds = RobotArmTargetIntent.jointBoundsRadians.map(\.upperBound)
        let lowerBounds = RobotArmTargetIntent.jointBoundsRadians.map(\.lowerBound)
        #expect(RobotArmTargetIntent(
            arm: .left,
            source: .visionProJointUI,
            positionsRadians: upperBounds,
            durationSeconds: 10
        ) != nil)
        #expect(RobotArmTargetIntent(
            arm: .left,
            source: .visionProJointUI,
            positionsRadians: lowerBounds,
            durationSeconds: 10
        ) != nil)
        for jointIndex in 0 ..< RobotArmTargetIntent.jointCount {
            var above = Array(repeating: 0.0, count: RobotArmTargetIntent.jointCount)
            above[jointIndex] = upperBounds[jointIndex] + 0.0001
            #expect(RobotArmTargetIntent(
                arm: .left,
                source: .visionProJointUI,
                positionsRadians: above,
                durationSeconds: 1
            ) == nil)
            var below = Array(repeating: 0.0, count: RobotArmTargetIntent.jointCount)
            below[jointIndex] = lowerBounds[jointIndex] - 0.0001
            #expect(RobotArmTargetIntent(
                arm: .left,
                source: .visionProJointUI,
                positionsRadians: below,
                durationSeconds: 1
            ) == nil)
        }
        let valid = try #require(
            RobotArmTargetIntent(
                arm: .left,
                source: .visionProJointUI,
                positionsRadians: Array(repeating: 0, count: 7),
                durationSeconds: 1
            )
        )
        #expect(throws: RobotArmWireError.self) {
            try RobotArmWireCodec.encodeTargetIntent(
                valid,
                messageID: messageID,
                senderID: senderID,
                sessionID: sessionID,
                sequence: 1,
                issuedAtUnixMilliseconds: now - 1_000,
                leaseMilliseconds: 250,
                nowUnixMilliseconds: now
            )
        }
    }

    @Test("Unknown fields and execution-eligible dispositions fail closed")
    func strictSchemaAndPreviewOnlyDisposition() throws {
        let extraFieldJSON = """
            {
              "protocol":"rob-arm-control/1",
              "schema_version":1,
              "type":"measured_state",
              "message_id":"11111111-2222-3333-4444-555555555555",
              "arm":"right",
              "sequence":1,
              "sampled_at_unix_ms":1725000000000,
              "sample_age_ms":1,
              "positions_rad":[0,0,0,0,0,0,0],
              "velocities_rad_s":[0,0,0,0,0,0,0],
              "currents":[0,0,0,0,0,0,0],
              "statuses":[0,0,0,0,0,0,0],
              "execute":true
            }
            """
        #expect(throws: RobotArmWireError.self) {
            try RobotArmWireCodec.decode(Data(extraFieldJSON.utf8))
        }

        let unsafeDisposition = """
            {
              "protocol":"rob-arm-control/1",
              "schema_version":1,
              "type":"target_disposition",
              "message_id":"11111111-2222-3333-4444-555555555555",
              "target_message_id":"11111111-2222-3333-4444-555555555555",
              "recipient_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
              "received_at_unix_ms":1725000000000,
              "disposition":"accepted_preview_only",
              "execution_eligible":true,
              "detail":"unsafe"
            }
            """
        #expect(throws: RobotArmWireError.self) {
            try RobotArmWireCodec.decode(Data(unsafeDisposition.utf8))
        }

        for kind in RobotArmTargetDispositionKind.allCases {
            let disposition = try #require(RobotArmTargetDisposition(
                targetMessageID: messageID,
                recipientID: senderID,
                receivedAtUnixMilliseconds: now,
                disposition: kind,
                executionEligible: false,
                detail: "Deterministic preview/rejection fixture."
            ))
            let encoded = try RobotArmWireCodec.encodeTargetDisposition(disposition)
            guard case .targetDisposition(let decoded) = try RobotArmWireCodec.decode(encoded)
            else {
                Issue.record("Expected target disposition")
                continue
            }
            #expect(decoded.executionEligible == false)
        }
    }

    @Test("Robot command envelope preserves bounded arm intent")
    func commandEnvelopeRoundTrip() throws {
        let target = try #require(
            RobotArmTargetIntent(
                arm: .left,
                source: .visionProSpatial,
                positionsRadians: Array(repeating: 0.2, count: 7),
                durationSeconds: 1
            )
        )
        let envelope = RobotCommandEnvelope(
            sessionID: sessionID,
            sequence: 3,
            issuedAt: Date(timeIntervalSince1970: Double(now) / 1_000),
            command: .armTargetIntent(target)
        )
        let decoded = try JSONDecoder().decode(
            RobotCommandEnvelope.self,
            from: JSONEncoder().encode(envelope)
        )
        #expect(decoded == envelope)
    }
}
