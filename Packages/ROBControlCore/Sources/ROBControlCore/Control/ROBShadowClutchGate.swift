import Foundation

/// A preview input latch, unrelated to actuator authority. Recovery always
/// requires a released grip; cached controller/button polls cannot freshen poses.
public struct ROBShadowClutchGate: Sendable {
    public private(set) var alignedTrackingID: UUID?
    public private(set) var isClutched = false
    public private(set) var requiresRelease = true
    private var lastSample: UInt64 = 0
    public init() {}
    public mutating func align(trackingID: UUID) {
        alignedTrackingID = trackingID; pause(); lastSample = 0
    }
    public mutating func pause() { isClutched = false; requiresRelease = true }
    public mutating func update(gripHeld: Bool, tracking: ROBShadowTrackingSample?, canSend: Bool, inputFresh: Bool = true) -> ROBShadowAction? {
        guard inputFresh else {
            let wasClutched = isClutched
            pause()
            return wasClutched ? .release : nil
        }
        guard gripHeld else {
            let wasClutched = isClutched
            isClutched = false; requiresRelease = false
            return wasClutched ? .release : nil
        }
        guard let tracking, tracking.quality == "tracked", tracking.isValid,
              tracking.ageMilliseconds <= 150, tracking.trackingID == alignedTrackingID else {
            let wasClutched = isClutched
            pause()
            if let tracking, tracking.trackingID != alignedTrackingID { alignedTrackingID = nil }
            return wasClutched ? .release : nil
        }
        guard !requiresRelease, canSend, tracking.sampleID > lastSample else { return nil }
        lastSample = tracking.sampleID
        if !isClutched { isClutched = true; return .clutch }
        return .pose
    }
}
