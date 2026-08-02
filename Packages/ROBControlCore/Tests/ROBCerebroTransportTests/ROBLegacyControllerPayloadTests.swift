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
        #expect(lines[6] == "touchPadL - 0.000000,0.250000")
        #expect(lines[7] == "touchPadR - 0.000000,0.083333")
        #expect(lines[9] == "tredBrakeLock=0")
    }

    @Test("Combined drive and turn remain inside the selected speed limit")
    func combinedAxesPreserveSpeedLimit() throws {
        let data = try ROBLegacyControllerPayload.controllerSnapshot(
            motion: MotionVector(linear: 0.65, angular: 0.65),
            senderID: UUID(),
            brakeIsLocked: false
        )
        let envelope = try #require(try decode(data))
        let message = try #require(envelope["message"] as? String)
        let lines = message.components(separatedBy: "\n")
        #expect(lines[6] == "touchPadL - 0.000000,0.325000")
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
