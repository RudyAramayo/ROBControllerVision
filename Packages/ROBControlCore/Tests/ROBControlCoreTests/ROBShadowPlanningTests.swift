import Foundation
import Testing
@testable import ROBControlCore

@Suite struct ROBShadowPlanningTests {
    let trackingID = UUID()
    func sample(id: UInt64 = 1, age: Double = 0, quality: String = "tracked") -> ROBShadowTrackingSample {
        .init(trackingID: trackingID, sampleID: id, ageMilliseconds: age, quality: quality,
              pose: .init(position: [0, 1, -0.5], quaternion: [0, 0, 0, 1]))
    }

    @Test func clutchRequiresReleaseAndFreshDistinctPoses() {
        var gate = ROBShadowClutchGate()
        gate.align(trackingID: trackingID)
        #expect(gate.update(gripHeld: true, tracking: sample(), canSend: true) == nil)
        #expect(gate.update(gripHeld: false, tracking: sample(), canSend: true) == nil)
        #expect(gate.update(gripHeld: true, tracking: sample(), canSend: true) == .clutch)
        #expect(gate.update(gripHeld: true, tracking: sample(), canSend: true) == nil)
        #expect(gate.update(gripHeld: true, tracking: sample(id: 2), canSend: false) == nil)
        #expect(gate.update(gripHeld: true, tracking: sample(id: 2), canSend: true) == .pose)
        #expect(gate.update(gripHeld: false, tracking: sample(id: 2), canSend: false) == .release)
    }

    @Test func trackingFailureCannotAutoResume() {
        for invalid in [sample(id: 2, age: 151), sample(id: 2, quality: "low_accuracy")] {
            var gate = ROBShadowClutchGate(); gate.align(trackingID: trackingID)
            _ = gate.update(gripHeld: false, tracking: sample(), canSend: true)
            #expect(gate.update(gripHeld: true, tracking: sample(), canSend: true) == .clutch)
            #expect(gate.update(gripHeld: true, tracking: invalid, canSend: true) == .release)
            #expect(gate.update(gripHeld: true, tracking: sample(id: 3), canSend: true) == nil)
            _ = gate.update(gripHeld: false, tracking: sample(id: 3), canSend: true)
            #expect(gate.update(gripHeld: true, tracking: sample(id: 4), canSend: true) == .clutch)
        }
    }

    @Test func originChangeInvalidatesAlignment() {
        var gate = ROBShadowClutchGate(); gate.align(trackingID: UUID())
        _ = gate.update(gripHeld: false, tracking: sample(), canSend: true)
        #expect(gate.update(gripHeld: true, tracking: sample(), canSend: true) == nil)
        #expect(gate.alignedTrackingID == nil)
    }

    @Test func lostControllerHeartbeatIsNotAGripRelease() {
        var gate = ROBShadowClutchGate(); gate.align(trackingID: trackingID)
        _ = gate.update(gripHeld: false, tracking: sample(), canSend: true)
        #expect(gate.update(gripHeld: true, tracking: sample(), canSend: true) == .clutch)
        #expect(gate.update(gripHeld: false, tracking: nil, canSend: true, inputFresh: false) == .release)
        #expect(gate.update(gripHeld: true, tracking: sample(id: 2), canSend: true) == nil)
        _ = gate.update(gripHeld: false, tracking: sample(id: 2), canSend: true)
        #expect(gate.update(gripHeld: true, tracking: sample(id: 3), canSend: true) == .clutch)
    }

    @Test func strictProtocolRejectsUnknownFieldsAndExecutionFlags() throws {
        let request = ROBShadowRequest(controllerID: UUID(), sessionID: UUID(), sequence: 1,
                                       command: .init(.start, shadowID: UUID()))
        let data = try ROBShadowProtocol.encode(request)
        #expect(try ROBShadowProtocol.request(data) == request)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["execute"] = true
        #expect(throws: (any Error).self) { try ROBShadowProtocol.request(JSONSerialization.data(withJSONObject: object)) }
        var response = ROBShadowResponse(request: request, status: "ready", detail: "Preview")
        response.hardwareOutputEnabled = true
        #expect(throws: (any Error).self) { try ROBShadowProtocol.response(ROBShadowProtocol.encode(response)) }
        #expect(ROBShadowProtocol.claims(Data("{\"protocol\":\"rob-shadow-ik/99\", malformed".utf8)))
    }

    @Test func agesUnitsAndQuaternionAreValidated() {
        let request = ROBShadowRequest(controllerID: UUID(), sessionID: UUID(), sequence: 1,
                                       command: .init(.start, shadowID: UUID()), sentAtMilliseconds: 1000)
        #expect(ROBShadowProtocol.fresh(request, now: 1100))
        #expect(!ROBShadowProtocol.fresh(request, now: 1600))
        #expect(!ROBShadowProtocol.fresh(request, now: 800))
        #expect(!ROBShadowPose(position: [0, 0, .nan], quaternion: [0, 0, 0, 1]).isValid)
        #expect(!ROBShadowPose(position: [0, 0, 0], quaternion: [0, 0, 0, 0]).isValid)
        #expect(!ROBShadowCommand(.nudge, shadowID: UUID(), modelID: String(repeating: "a", count: 64), delta: [1, 0, 0]).isValid)
    }
}
