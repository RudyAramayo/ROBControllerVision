import Foundation
import Testing

@testable import ROBControlCore

@Suite("Supervised robot action approval protocol")
struct RobotActionProtocolTests {
    private let controllerID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private let cerebroID = "cerebro-main"
    private let now: Int64 = 1_725_000_000_000

    @Test("Controller availability survives the legacy application-data envelope")
    func controllerHelloArchiveRoundTrip() throws {
        let hello = try RobotActionMessage.controllerHello(
            senderID: controllerID,
            acceptsActions: true
        )
        let archive = try RobotActionWireCodec.archive(hello)
        let decoded = try #require(try RobotActionWireCodec.decodeArchive(archive))
        #expect(decoded == hello)
        #expect(decoded.acceptsActions == true)
        #expect(Set(decoded.capabilities) == Set(RobotActionName.allCases))
    }

    @Test("Cerebro action requests decode with an immutable deadline and exact arguments")
    func requestGoldenFixture() throws {
        let json = """
            {
              "schema":"com.orbitusrobotics.robot-action",
              "version":1,
              "message_id":"request-1",
              "kind":"action_request",
              "call_id":"tool-call-1",
              "sender_id":"cerebro-main",
              "recipient_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
              "sent_at_ms":1725000000000,
              "expires_at_ms":1725000030000,
              "action":"play_gesture",
              "arguments":{"gesture":"friendly_wave"},
              "state":"pending"
            }
            """
        let request = try RobotActionWireCodec.decodeJSON(Data(json.utf8))
        #expect(request.kind == .actionRequest)
        #expect(request.callID == "tool-call-1")
        #expect(request.recipientID == controllerID)
        #expect(request.action == .playGesture)
        #expect(request.arguments["gesture"] == .string("friendly_wave"))

        let accepted = try RobotActionMessage.status(
            for: request,
            state: .accepted,
            detail: "Operator approved while supervising beside the droid.",
            senderID: controllerID
        )
        let response = try RobotActionWireCodec.decodeJSON(
            RobotActionWireCodec.encodeJSON(accepted)
        )
        #expect(response.callID == request.callID)
        #expect(response.recipientID == cerebroID)
        #expect(response.state == .accepted)
    }

    @Test("Headless arm approval carries one immutable bounded operation")
    func armOperationRoundTrip() throws {
        let args: [String: RobotActionJSONValue] = ["operation": .string("relax"), "arm": .string("both"),
            "summary": .string("Lower gently to hanging then deactivate")]
        let request = try RobotActionMessage(kind: .actionRequest, callID: "arm-request", senderID: "Cerebro.arm-operations",
            recipientID: controllerID, sentAtMilliseconds: now, expiresAtMilliseconds: now + 30_000,
            action: .armOperation, arguments: args, state: .pending)
        #expect(try RobotActionWireCodec.decodeArchive(RobotActionWireCodec.archive(request)) == request)
        for extra in [["force": RobotActionJSONValue.number(1000)], ["operation": .string("arbitrary")], ["arm": .string("unknown")]] {
            #expect(throws: (any Error).self) {
                try RobotActionMessage(kind: .actionRequest, callID: "bad-arm-request", senderID: cerebroID,
                    sentAtMilliseconds: now, expiresAtMilliseconds: now + 30_000, action: .armOperation,
                    arguments: args.merging(extra) { _, replacement in replacement }, state: .pending)
            }
        }
    }

    @Test("Model-supplied joint arrays and unknown action arguments fail closed")
    func strictActionArguments() throws {
        let unsafe = """
            {
              "schema":"com.orbitusrobotics.robot-action",
              "version":1,
              "message_id":"request-unsafe",
              "kind":"action_request",
              "call_id":"tool-call-unsafe",
              "sender_id":"cerebro-main",
              "sent_at_ms":1725000000000,
              "expires_at_ms":1725000030000,
              "action":"play_gesture",
              "arguments":{"gesture":"friendly_wave","joint_positions":[0,0,0,0,0,0,0]},
              "state":"pending"
            }
            """
        #expect(throws: (any Error).self) {
            try RobotActionWireCodec.decodeJSON(Data(unsafe.utf8))
        }

        let unsafeStop = """
            {
              "schema":"com.orbitusrobotics.robot-action",
              "version":1,
              "message_id":"request-stop",
              "kind":"action_request",
              "call_id":"tool-call-stop",
              "sender_id":"cerebro-main",
              "sent_at_ms":1725000000000,
              "expires_at_ms":1725000030000,
              "action":"stop_motion",
              "arguments":{"force":true},
              "state":"pending"
            }
            """
        #expect(throws: (any Error).self) {
            try RobotActionWireCodec.decodeJSON(Data(unsafeStop.utf8))
        }

        let startup = try RobotActionMessage(
            kind: .actionRequest,
            callID: "headless-startup-1",
            senderID: cerebroID,
            recipientID: controllerID,
            sentAtMilliseconds: now,
            expiresAtMilliseconds: now + 30_000,
            action: .runStartupTest,
            arguments: ["gesture": .string("startup.wake-both")],
            state: .pending
        )
        #expect(startup.action == .runStartupTest)
        #expect(throws: (any Error).self) {
            try RobotActionMessage(
                kind: .actionRequest,
                callID: "headless-startup-unsafe",
                senderID: cerebroID,
                recipientID: controllerID,
                sentAtMilliseconds: now,
                expiresAtMilliseconds: now + 30_000,
                action: .runStartupTest,
                arguments: [
                    "gesture": .string("startup.wake-both"),
                    "positions_rad": .array([.number(0)])
                ],
                state: .pending
            )
        }
    }

    @Test("Oversized, malformed, and envelope-spoofed messages are rejected")
    func failClosedWireBoundary() throws {
        #expect(throws: (any Error).self) {
            try RobotActionWireCodec.decodeJSON(
                Data(repeating: 0x61, count: RobotActionMessage.maximumPayloadBytes + 1)
            )
        }

        let hello = try RobotActionMessage.controllerHello(
            senderID: controllerID,
            acceptsActions: true
        )
        let payload = try RobotActionWireCodec.encodeJSON(hello)
        let spoofed: NSDictionary = [
            "message": RobotActionMessage.envelopeMarker,
            "sender": "different-controller",
            "robot_action": payload,
        ]
        let archive = try NSKeyedArchiver.archivedData(
            withRootObject: spoofed,
            requiringSecureCoding: false
        )
        #expect(throws: RobotActionProtocolError.self) {
            try RobotActionWireCodec.decodeArchive(archive)
        }
    }
}
