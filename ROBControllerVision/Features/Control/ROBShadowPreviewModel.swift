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
    @Published private(set) var aligned = false
    @Published private(set) var isRecordedReplay = false
    var send: ((ROBShadowCommand) async throws -> Void)?
    private var shadowID = UUID()
    private var gate = ROBShadowClutchGate()
    private var sample: ROBShadowTrackingSample?
    private var sampleReceived = 0.0
    @Published private var gripHeld = false
    @Published private var trackingAvailable = false
    private var controllerConnected = false
    private var sendTask: Task<Void, Never>?
    private var gripReceived = 0.0
    private var pending: ROBShadowCommand?
    private var sentAt = 0.0
    private var ticker: Task<Void, Never>?
    private let uptime: () -> Double

    init(uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.uptime = uptime }
    var canAlign: Bool { response != nil && !waiting && trackingAvailable }
    var canNudge: Bool { !isRecordedReplay && response != nil && !waiting && !gripHeld && response?.status != "unavailable" }
    var trackingDetail: String {
        guard let sample = freshSample() else { return "Waiting for a fresh left-controller pose" }
        return sample.quality == "tracked" ? "Left controller tracked" : "Tracking uncertain — preview held"
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
        shadowID = UUID(); response = nil; gate = ROBShadowClutchGate(); aligned = false
        issue(.init(.start, shadowID: shadowID))
    }
    func alignForward() {
        guard canAlign, let tracking = freshSample(), let modelID = response?.modelID else { return }
        gate.pause()
        issue(.init(.align, shadowID: shadowID, modelID: modelID, tracking: tracking))
    }
    func nudge(axis: Int, sign: Double) {
        guard canNudge, (0..<3).contains(axis), let modelID = response?.modelID else { return }
        var delta = [0.0, 0.0, 0.0]; delta[axis] = sign * (precision ? 0.002 : 0.01)
        gate.pause()
        issue(.init(.nudge, shadowID: shadowID, modelID: modelID, delta: delta))
    }
    func tracking(_ value: ROBShadowTrackingSample?) { sample = value; sampleReceived = uptime() }
    func grip(_ held: Bool, connected: Bool) {
        if gripHeld != held { gripHeld = held }
        controllerConnected = connected; gripReceived = uptime()
    }
    func consume(_ value: ROBShadowResponse) {
        guard visible, value.shadowID == shadowID, value.requestID == pending?.requestID,
              response == nil || response?.modelID == value.modelID else { return }
        let completed = pending
        pending = nil; waiting = false
        if !value.ghostFrames.isEmpty { response = value }
        detail = value.detail
        if value.status == "aligned", let id = completed?.tracking?.trackingID {
            gate.align(trackingID: id); aligned = true
        } else if ["paused", "unavailable", "ended"].contains(value.status) {
            gate.pause()
            if value.status == "unavailable" { response = nil; aligned = false }
        }
    }
    func poll() {
        guard visible else { return }
        let available = freshSample()?.quality == "tracked"
        if trackingAvailable != available { trackingAvailable = available }
        if waiting && uptime() - sentAt > (pending?.action == .start ? 9 : 2.5) {
            pending = nil; waiting = false; gate.pause(); aligned = false; response = nil
            detail = "Mac preview timed out. Load the reference again; release the grip before resuming."
        }
        let inputFresh = controllerConnected && uptime() - gripReceived <= 0.25
        guard let modelID = response?.modelID else { return }
        let current = freshSample()
        if let action = gate.update(gripHeld: gripHeld, tracking: current, canSend: !waiting, inputFresh: inputFresh) {
            issue(.init(action, shadowID: shadowID, modelID: modelID,
                        tracking: action == .release ? nil : current,
                        translationScale: action == .clutch ? (precision ? 0.2 : 1) : nil))
        }
        aligned = gate.alignedTrackingID != nil
    }
    func suspend() {
        guard controllerConnected || gate.isClutched || sample != nil else { return }
        if let modelID = response?.modelID {
            issue(.init(.release, shadowID: shadowID, modelID: modelID))
        }
        gate.pause(); controllerConnected = false; gripHeld = false; sample = nil
    }
    func close() {
        if !isRecordedReplay && (response != nil || pending != nil) {
            issue(.init(.end, shadowID: shadowID, modelID: response?.modelID))
        }
        visible = false; isRecordedReplay = false; ticker?.cancel(); ticker = nil
        gate = ROBShadowClutchGate(); pending = nil; response = nil; waiting = false; aligned = false
    }
    func disconnected() {
        guard !isRecordedReplay else { return }
        gate = ROBShadowClutchGate(); pending = nil; response = nil; waiting = false; aligned = false
        sample = nil; controllerConnected = false; gripHeld = false
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
    private func freshSample() -> ROBShadowTrackingSample? {
        guard var sample else { return nil }
        sample.ageMilliseconds += max(0, uptime() - sampleReceived) * 1000
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
                self?.pending = nil; self?.waiting = false; self?.gate.pause()
                self?.detail = "Shadow request failed: \(error.localizedDescription)"
            }
        }
    }
}
