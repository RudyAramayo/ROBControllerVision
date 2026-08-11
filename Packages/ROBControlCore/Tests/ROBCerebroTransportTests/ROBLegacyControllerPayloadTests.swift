import Foundation
import ROBControlCore
import Testing

@testable import ROBCerebroTransport

@Suite("Cerebro controller compatibility payload")
struct ROBLegacyControllerPayloadTests {
    @Test("Differential drive maps to Cerebro's bounded tread snapshot")
    func differentialDriveSnapshot() throws {
        let senderID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let data = try ROBLegacyControllerPayload.controllerSnapshot(
            motion: MotionVector(linear: 0.5, angular: 0.25),
            senderID: senderID,
            brakeIsLocked: false
        )
        let envelope = try #require(try decode(data))
        #expect(envelope["sender"] as? String == senderID.uuidString.lowercased())
        let message = try #require(envelope["message"] as? String)
        let lines = message.components(separatedBy: "\n")
        #expect(lines.count == 14)
        #expect(lines[6] == "touchPadL - 0.000000,0.375000")
        #expect(lines[7] == "touchPadR - 0.000000,0.125000")
        #expect(lines[9] == "tredBrakeLock=0")
    }

    @Test("Independent tread demands clamp without cross-normalization")
    func independentTreadsClampIndividually() throws {
        let data = try ROBLegacyControllerPayload.controllerSnapshot(
            motion: MotionVector(linear: 0.65, angular: 0.65),
            senderID: UUID(),
            brakeIsLocked: false
        )
        let envelope = try #require(try decode(data))
        let message = try #require(envelope["message"] as? String)
        let lines = message.components(separatedBy: "\n")
        #expect(lines[6] == "touchPadL - 0.000000,0.500000")
        #expect(lines[7] == "touchPadR - 0.000000,0.000000")
    }

    @Test("Stopped snapshot requests both tread brakes")
    func stoppedSnapshot() throws {
        let data = try ROBLegacyControllerPayload.stoppedSnapshot(senderID: UUID())
        let envelope = try #require(try decode(data))
        let message = try #require(envelope["message"] as? String)
        #expect(message.contains("touchPadL - 0.000000,-1000.000000"))
        #expect(message.contains("touchPadR - 0.000000,-1000.000000"))
        #expect(message.contains("tredBrakeLock=1"))
    }

    @Test("Spatial controller poses are versioned beside the legacy snapshot")
    func spatialControllerPoses() throws {
        let left = try #require(ControllerPose(
            x: 0.125, y: 1.25, z: -0.5,
            qx: 0, qy: 0.7071068, qz: 0, qw: 0.7071068,
            timestamp: 1_786_435_200.25
        ))
        let right = try #require(ControllerPose(
            x: -0.25, y: 1.125, z: -0.625,
            qx: 0, qy: 0, qz: 0, qw: 1,
            timestamp: 1_786_435_200.5
        ))
        let data = try ROBLegacyControllerPayload.controllerSnapshot(
            motion: .stopped,
            senderID: UUID(),
            brakeIsLocked: false,
            controllerPoses: ControllerPosePair(left: left, right: right)
        )
        let envelope = try #require(try decode(data))
        #expect(envelope["controller.pose.version"] as? String == "1")
        #expect(
            envelope["controller.pose.left"] as? String
                == "0.125000,1.250000,-0.500000,0.0000000,0.7071068,0.0000000,0.7071068,1786435200.250000"
        )
        #expect(
            envelope["controller.pose.right"] as? String
                == "-0.250000,1.125000,-0.625000,0.0000000,0.0000000,0.0000000,1.0000000,1786435200.500000"
        )
    }

    @Test("Authority request uses the installed controller identity")
    func authorityRequest() throws {
        let senderID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let data = try ROBLegacyControllerPayload.requestMotionAuthority(senderID: senderID)
        let envelope = try #require(try decode(data))
        #expect(envelope["message"] as? String == "RequestToBeMasterController")
        #expect(envelope["sender"] as? String == senderID.uuidString.lowercased())
    }

    private func decode(_ data: Data) throws -> NSDictionary? {
        try NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSDictionary.self, NSString.self],
            from: data
        ) as? NSDictionary
    }
}
