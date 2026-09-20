import Foundation
import Combine
#if canImport(ROBControlCore)
import ROBControlCore
#endif

@MainActor final class ROBShadowPreviewModel: ObservableObject {
    @Published private(set) var response: ROBShadowResponse?
    @Published private(set) var detail = "Connect to Cerebro, then load the scan reference."
    @Published private(set) var waiting = false
    @Published private(set) var visible = false
    @Published var precision = true
    @Published var selectedArm: ROBShadowArm = .left
    @Published var requireVision = true
    var aligned: Bool { lanes[selectedArm]!.gate.alignedTrackingID != nil }
    @Published private(set) var isRecordedReplay = false
    var send: ((ROBShadowCommand) async throws -> Void)?
    private var shadowID = UUID()
    private struct Lane {
        var gate = ROBShadowClutchGate()
        var sample: ROBShadowTrackingSample?
        var sampleReceived = 0.0
        var gripHeld = false
        var connected = false
        var gripReceived = 0.0
    }
    private var lanes: [ROBShadowArm: Lane] = [.left: Lane(), .right: Lane()]
    private var lastArm: ROBShadowArm = .right
    private var lastRefresh = 0.0
    private var sendTask: Task<Void, Never>?
    private var pending: ROBShadowCommand?
    private var sentAt = 0.0
    private var ticker: Task<Void, Never>?
    private let uptime: () -> Double

    init(uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.uptime = uptime }
    var canAlign: Bool { !isRecordedReplay && response != nil && !waiting && freshSample(selectedArm)?.quality == "tracked" }
    var canNudge: Bool { !isRecordedReplay && response != nil && !waiting && !lanes.values.contains(where: { $0.gripHeld }) && response?.status != "unavailable" }
    var trackingDetail: String {
        guard let sample = freshSample(selectedArm) else { return "Waiting for a fresh \(selectedArm.rawValue)-controller pose" }
        return sample.quality == "tracked" ? "\(selectedArm.rawValue.capitalized) controller tracked" : "Tracking uncertain — preview held"
    }
    func open() {
        visible = true
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }
    func start() {
        isRecordedReplay = false
        shadowID = UUID(); response = nil; pauseAll(resetAlignment: true); lastRefresh = uptime()
        issue(.init(.start, shadowID: shadowID, arm: selectedArm, visionRequired: requireVision))
    }
    func alignForward() {
        guard canAlign, let tracking = freshSample(selectedArm), let modelID = response?.modelID else { return }
        lanes[selectedArm]!.gate.pause()
        issue(.init(.align, shadowID: shadowID, modelID: modelID, tracking: tracking, arm: selectedArm))
    }
    func nudge(axis: Int, sign: Double) {
        guard canNudge, (0..<3).contains(axis), let modelID = response?.modelID else { return }
        var delta = [0.0, 0.0, 0.0]; delta[axis] = sign * (precision ? 0.002 : 0.01)
        lanes[selectedArm]!.gate.pause()
        issue(.init(.nudge, shadowID: shadowID, modelID: modelID, delta: delta, arm: selectedArm))
    }
    func tracking(_ value: ROBShadowTrackingSample?, arm: ROBShadowArm = .left) {
        lanes[arm]!.sample = value; lanes[arm]!.sampleReceived = uptime()
    }
    func grip(_ held: Bool, connected: Bool, arm: ROBShadowArm = .left) {
        lanes[arm]!.gripHeld = held; lanes[arm]!.connected = connected; lanes[arm]!.gripReceived = uptime()
    }
    func consume(_ value: ROBShadowResponse) {
        guard visible, value.shadowID == shadowID, value.requestID == pending?.requestID, value.arm == pending?.arm,
              response == nil || response?.modelID == value.modelID else { return }
        let completed = pending
        pending = nil; waiting = false
        if value.status == "ended" {
            response = nil; pauseAll(resetAlignment: true); detail = value.detail
            return
        }
        if !value.ghostFrames.isEmpty { response = value }
        detail = value.detail
        if value.status == "aligned", let id = completed?.tracking?.trackingID {
            lanes[value.arm]!.gate.align(trackingID: id)
        } else if ["paused", "blocked", "unavailable", "ended"].contains(value.status) {
            lanes[value.arm]!.gate.pause()
            if value.status == "unavailable" { response = nil; pauseAll(resetAlignment: true) }
            if completed?.action == .refresh { pauseAll() }
        }
    }
    func poll() {
        guard visible else { return }
        objectWillChange.send()
        if waiting && uptime() - sentAt > (pending?.action == .start ? 9 : 2.5) {
            pending = nil; waiting = false; pauseAll(resetAlignment: true); response = nil
            detail = "Mac preview timed out. Load the reference again; release the grips before resuming."
        }
        guard let modelID = response?.modelID, !isRecordedReplay else { return }
        // Alternate priority when both hands are active. There is one shared
        // ghost and one solve in flight, with independent origin/grip latches.
        let order: [ROBShadowArm] = lastArm == .left ? [.right, .left] : [.left, .right]
        for arm in order {
            var lane = lanes[arm]!
            let current = freshSample(arm)
            let action = lane.gate.update(gripHeld: lane.gripHeld, tracking: current, canSend: !waiting,
                inputFresh: lane.connected && uptime() - lane.gripReceived <= 0.25)
            lanes[arm] = lane
            if let action {
                lastArm = arm
                issue(.init(action, shadowID: shadowID, modelID: modelID,
                            tracking: action == .release ? nil : current,
                            translationScale: action == .clutch ? (precision ? 0.2 : 1) : nil, arm: arm))
                return
            }
        }
        if !waiting && uptime() - lastRefresh >= 0.25 {
            lastRefresh = uptime()
            issue(.init(.refresh, shadowID: shadowID, modelID: modelID, arm: selectedArm))
        }
    }
    func suspend() {
        guard lanes.values.contains(where: { $0.connected || $0.gate.isClutched || $0.sample != nil }) else { return }
        if let modelID = response?.modelID {
            // End rather than queue two releases behind an old target. Reopen
            // the preview to establish a fresh session after live authority.
            issue(.init(.end, shadowID: shadowID, modelID: modelID, arm: selectedArm))
        }
        lanes = [.left: Lane(), .right: Lane()]; response = nil
    }
    private func pauseAll(resetAlignment: Bool = false) {
        for arm in ROBShadowArm.allCases {
            if resetAlignment { lanes[arm]!.gate = ROBShadowClutchGate() }
            else { lanes[arm]!.gate.pause() }
        }
    }
    func close() {
        if !isRecordedReplay && (response != nil || pending != nil) {
            issue(.init(.end, shadowID: shadowID, modelID: response?.modelID, arm: selectedArm))
        }
        visible = false; isRecordedReplay = false; ticker?.cancel(); ticker = nil
        pauseAll(resetAlignment: true); pending = nil; response = nil; waiting = false
    }
    func disconnected() {
        guard !isRecordedReplay else { return }
        pauseAll(resetAlignment: true); pending = nil; response = nil; waiting = false
        lanes = [.left: Lane(), .right: Lane()]
        detail = "Connect to the updated Cerebro app, then load the reference again."
    }
    #if DEBUG
    func loadSimulatorReplay() {
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shadow-preview-replay.json")
        do {
            let value = try ROBShadowProtocol.response(Data(contentsOf: path))
            isRecordedReplay = true
            response = value
            detail = "Recorded Mac Drake response • simulator replay • no robot connection"
        } catch { detail = "Replay unavailable: \(error.localizedDescription)" }
    }
    #endif
    private func freshSample(_ arm: ROBShadowArm) -> ROBShadowTrackingSample? {
        guard var sample = lanes[arm]!.sample else { return nil }
        sample.ageMilliseconds += max(0, uptime() - lanes[arm]!.sampleReceived) * 1000
        return sample.isValid && sample.ageMilliseconds <= 150 ? sample : nil
    }
    private func issue(_ command: ROBShadowCommand) {
        guard let send else { detail = "Connect to Cerebro to use Mac shadow IK."; return }
        pending = command; waiting = true; sentAt = uptime()
        let previousSend = sendTask
        sendTask = Task { [weak self] in
            await previousSend?.value
            do { try await send(command) }
            catch {
                guard self?.pending?.requestID == command.requestID else { return }
                self?.pending = nil; self?.waiting = false; self?.pauseAll()
                self?.detail = "Shadow request failed: \(error.localizedDescription)"
            }
        }
    }
}
