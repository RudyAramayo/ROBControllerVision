import Foundation
import Testing

@testable import ROBControlCore

@Suite("Calibrated Amber gripper-control transport")
struct GripperControlProtocolTests {
    private let messageID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let senderID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let sessionID = UUID(uuidString: "12345678-1234-5678-9abc-def012345678")!
    private let now: Int64 = 1_725_000_000_000

    @Test("Vision emits an authenticated leased edge with conservative force")
    func commandIntentRoundTrip() throws {
        let intent = try #require(
            RobotGripperCommandIntent(arm: .left, action: .hold, force: 12)
        )
        let data = try RobotGripperWireCodec.encodeCommandIntent(
            intent,
            messageID: messageID,
            senderID: senderID,
            sessionID: sessionID,
            sequence: 7,
            issuedAtUnixMilliseconds: now,
            leaseMilliseconds: 750,
            deadManHeld: true,
            nowUnixMilliseconds: now
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["protocol"] as? String == "rob-gripper-control/1")
        #expect(object["type"] as? String == "command_intent")
        #expect(object["action"] as? String == "hold")
        #expect(object["force"] as? Int == 12)
        #expect(object["dead_man_held"] as? Bool == true)
        #expect(Set(object.keys) == [
            "protocol", "schema_version", "type", "message_id", "sender_id", "session_id",
            "sequence", "issued_at_unix_ms", "lease_ms", "arm", "action", "force",
            "dead_man_held",
        ])
        guard case .commandIntent(let decoded) = try RobotGripperWireCodec.decode(
            data,
            nowUnixMilliseconds: now
        ) else {
            Issue.record("Expected a gripper command intent")
            return
        }
        #expect(decoded.senderID == senderID)
        #expect(decoded.sessionID == sessionID)
        #expect(decoded.force == 12)
    }

    @Test("Vision force, lease, dead-man, and schema fail closed")
    func commandBoundsFailClosed() throws {
        #expect(RobotGripperCommandIntent(arm: .left, action: .hold, force: 1) == nil)
        #expect(RobotGripperCommandIntent(arm: .right, action: .hold, force: 21) == nil)
        let intent = try #require(
            RobotGripperCommandIntent(arm: .right, action: .release, force: 5)
        )
        #expect(throws: RobotGripperWireError.self) {
            try RobotGripperWireCodec.encodeCommandIntent(
                intent,
                messageID: messageID,
                senderID: senderID,
                sessionID: sessionID,
                sequence: 1,
                issuedAtUnixMilliseconds: now,
                leaseMilliseconds: 750,
                deadManHeld: false,
                nowUnixMilliseconds: now
            )
        }
        #expect(throws: RobotGripperWireError.self) {
            try RobotGripperWireCodec.encodeCommandIntent(
                intent,
                messageID: messageID,
                senderID: senderID,
                sessionID: sessionID,
                sequence: 2,
                issuedAtUnixMilliseconds: now - 751,
                leaseMilliseconds: 750,
                deadManHeld: true,
                nowUnixMilliseconds: now
            )
        }

        let valid = try RobotGripperWireCodec.encodeCommandIntent(
            intent,
            messageID: messageID,
            senderID: senderID,
            sessionID: sessionID,
            sequence: 3,
            issuedAtUnixMilliseconds: now,
            leaseMilliseconds: 750,
            deadManHeld: true,
            nowUnixMilliseconds: now
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: valid) as? [String: Any]
        )
        object["raw_position"] = 255
        #expect(throws: RobotGripperWireError.self) {
            try RobotGripperWireCodec.decode(
                JSONSerialization.data(withJSONObject: object),
                nowUnixMilliseconds: now
            )
        }
    }

    @Test("State never claims physical calibration or force feedback")
    func unverifiedStateRoundTrip() throws {
        let state = try #require(
            RobotGripperState(
                messageID: messageID,
                arm: .right,
                sequence: 4,
                sampledAtUnixMilliseconds: now,
                calibrationState: .commandAcceptedUnverified,
                calibrationVerified: false,
                feedbackAvailable: false,
                commandInFlight: false,
                lastAction: .hold,
                lastForce: 10,
                detail: "Amber accepted dispatch; completion is unverified."
            )
        )
        let data = try RobotGripperWireCodec.encodeState(state)
        guard case .state(let decoded) = try RobotGripperWireCodec.decode(data) else {
            Issue.record("Expected gripper state")
            return
        }
        #expect(decoded == state)
        #expect(!decoded.calibrationVerified)
        #expect(!decoded.feedbackAvailable)

        #expect(RobotGripperState(
            arm: .left,
            sequence: 1,
            sampledAtUnixMilliseconds: now,
            calibrationState: .commandAcceptedUnverified,
            calibrationVerified: true,
            feedbackAvailable: false,
            commandInFlight: false,
            lastAction: nil,
            lastForce: nil,
            detail: "False verified claim"
        ) == nil)
    }

    @Test("Targeted dispositions and per-arm snapshots retain calibration truth")
    func dispositionAndSnapshot() throws {
        let disposition = try #require(
            RobotGripperCommandDisposition(
                requestMessageID: messageID,
                recipientID: senderID,
                sessionID: sessionID,
                arm: .left,
                receivedAtUnixMilliseconds: now,
                disposition: .dispatchAcknowledgedUnverified,
                terminal: true,
                detail: "Core dispatch acknowledged; completion unverified.",
                calibrationState: .commandAcceptedUnverified,
                calibrationVerified: false,
                feedbackAvailable: false,
                action: .hold,
                force: 8
            )
        )
        let data = try RobotGripperWireCodec.encodeCommandDisposition(disposition)
        guard case .commandDisposition(let decoded) = try RobotGripperWireCodec.decode(data)
        else {
            Issue.record("Expected gripper disposition")
            return
        }
        #expect(decoded == disposition)

        var snapshot = RobotGripperTelemetrySnapshot()
        let state = try #require(RobotGripperState(
            arm: .left,
            sequence: 2,
            sampledAtUnixMilliseconds: now,
            calibrationState: .required,
            calibrationVerified: false,
            feedbackAvailable: false,
            commandInFlight: false,
            lastAction: nil,
            lastForce: nil,
            detail: "Calibration required."
        ))
        snapshot.apply(state)
        snapshot.apply(try #require(RobotGripperState(
            arm: .left,
            sequence: 1,
            sampledAtUnixMilliseconds: now,
            calibrationState: .commandAcceptedUnverified,
            calibrationVerified: false,
            feedbackAvailable: false,
            commandInFlight: false,
            lastAction: nil,
            lastForce: nil,
            detail: "Stale."
        )))
        #expect(snapshot.left == state)
    }
}
