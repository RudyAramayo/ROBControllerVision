import Foundation

@main struct ROBShadowPreviewModelFixtureTests {
    @MainActor static func main() async throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: "ShadowPreviewFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        var now = 1000.0, commands: [ROBShadowCommand] = []
        let model = ROBShadowPreviewModel(uptime: { now })
        model.send = { command in commands.append(command) }
        model.open(); model.start()
        try await Task.sleep(for: .milliseconds(20))
        let start = commands.last!
        let request = ROBShadowRequest(controllerID: UUID(), sessionID: UUID(), sequence: 1, command: start)
        var reference = ROBShadowResponse(request: request, status: "ready", detail: "scan reference")
        reference.modelID = String(repeating: "a", count: 64)
        reference.referenceID = String(repeating: "b", count: 64)
        reference.ghostFrames = [ROBShadowFrame(name: "left_tool", pose: .init(position: [0, 0, 1], quaternion: [0, 0, 0, 1]))]
        model.consume(reference)
        try expect(model.response != nil && !model.waiting, "Valid reference did not enable preview")
        let id = UUID()
        func sample(_ sequence: UInt64) -> ROBShadowTrackingSample {
            .init(trackingID: id, sampleID: sequence, ageMilliseconds: 0, quality: "tracked",
                  pose: .init(position: [0, 1, -0.5], quaternion: [0, 0, 0, 1]))
        }
        model.tracking(sample(1)); model.poll()
        try expect(model.canAlign, "Fresh tracking did not enable alignment")
        model.alignForward()
        try await Task.sleep(for: .milliseconds(20))
        let align = commands.last!
        var aligned = reference; aligned.requestID = align.requestID; aligned.status = "aligned"
        model.consume(aligned)
        model.grip(false, connected: true); model.poll()
        model.grip(true, connected: true); model.tracking(sample(2)); model.poll()
        try await Task.sleep(for: .milliseconds(20))
        try expect(commands.last?.action == .clutch, "Fresh grip did not clutch")
        let clutchID = commands.last!.requestID
        model.grip(false, connected: true); model.poll()
        try await Task.sleep(for: .milliseconds(20))
        try expect(commands.last?.action == .release, "Grip release failed to preempt pending clutch")
        var late = reference; late.requestID = clutchID; late.status = "clutched"
        model.consume(late)
        try expect(model.response?.status != "clutched", "Late clutch resurrected a released gesture")
        var released = reference; released.requestID = commands.last!.requestID; released.status = "paused"
        model.consume(released)
        model.grip(false, connected: true); model.poll()
        model.grip(true, connected: true); model.tracking(sample(3)); model.poll()
        try await Task.sleep(for: .milliseconds(20))
        var clutched = reference; clutched.requestID = commands.last!.requestID; clutched.status = "clutched"
        model.consume(clutched)
        now += 0.3; model.poll()
        try await Task.sleep(for: .milliseconds(20))
        try expect(commands.last?.action == .release, "Missing input heartbeat did not pause")
        released.requestID = commands.last!.requestID; model.consume(released)
        let count = commands.count
        model.grip(true, connected: true); model.tracking(sample(4)); model.poll()
        try await Task.sleep(for: .milliseconds(20))
        try expect(!commands.dropFirst(count).contains(where: { $0.action == .pose || $0.action == .clutch }), "Held grip automatically resumed after a gap")
        if commands.last?.action == .refresh {
            var refresh = reference; refresh.requestID = commands.last!.requestID
            model.consume(refresh)
        }
        model.selectedArm = .right
        let rightSample = ROBShadowTrackingSample(trackingID: UUID(), sampleID: 1, ageMilliseconds: 0,
            quality: "tracked", pose: .init(position: [0.2, 1, -0.5], quaternion: [0, 0, 0, 1]))
        model.tracking(rightSample, arm: .right); model.poll(); model.alignForward()
        try await Task.sleep(for: .milliseconds(20))
        try expect(commands.last?.arm == .right && commands.last?.action == .align, "Right controller did not align its own arm")
        var rightAligned = reference; rightAligned.arm = .right; rightAligned.requestID = commands.last!.requestID; rightAligned.status = "aligned"
        model.consume(rightAligned)
        model.grip(false, connected: true, arm: .right); model.poll()
        var nextRight = rightSample; nextRight.sampleID = 2
        model.grip(true, connected: true, arm: .right); model.tracking(nextRight, arm: .right); model.poll()
        try await Task.sleep(for: .milliseconds(20))
        try expect(commands.last?.arm == .right && commands.last?.action == .clutch, "Right grip did not use right arm")
        var wrongArm = reference; wrongArm.requestID = commands.last!.requestID; wrongArm.status = "clutched"
        model.consume(wrongArm)
        try expect(model.waiting, "Wrong-arm response acknowledged the right controller")
        model.suspend()
        try await Task.sleep(for: .milliseconds(20))
        try expect(commands.last?.action == .end, "Authority suspension did not end both input lanes")
        var ended = reference; ended.arm = .right; ended.requestID = commands.last!.requestID; ended.status = "ended"
        model.consume(ended)
        try expect(model.response == nil, "End acknowledgement revived a suspended preview")
        model.close()
        try await Task.sleep(for: .milliseconds(20))
        try expect(commands.last?.action == .end && !model.visible, "Closing failed to end session")
        model.open(); model.start(); model.close()
        try await Task.sleep(for: .milliseconds(20))
        try expect(commands.last?.action == .end && commands.last?.modelID == nil, "Closing during startup leaked the Mac worker")
        print("Shadow preview model passed: both controllers, wrong-arm/late reply rejection, grip loss, authority suspension, startup cancellation")
    }
}
