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
        try expect(commands.count == count, "Held grip automatically resumed after a gap")
        model.close()
        try await Task.sleep(for: .milliseconds(20))
        try expect(commands.last?.action == .end && !model.visible, "Closing failed to end session")
        model.open(); model.start(); model.close()
        try await Task.sleep(for: .milliseconds(20))
        try expect(commands.last?.action == .end && commands.last?.modelID == nil, "Closing during startup leaked the Mac worker")
        print("Shadow preview model passed: reference handshake, tracked alignment, clutch/release, late result, input gap, startup cancellation")
    }
}
