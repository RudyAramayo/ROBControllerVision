import Foundation

// Kept byte-identical in ROBControllerVision/Packages/ROBControlCore. This
// protocol has no execution, authority, driver-coordinate or motor messages.
public enum ROBShadowAction: String, Codable, Sendable {
    case start, align, clutch, pose, release, nudge, end, refresh
}

public enum ROBShadowArm: String, Codable, CaseIterable, Sendable { case left, right }

public struct ROBShadowPose: Codable, Equatable, Sendable {
    public var position: [Double]
    public var quaternion: [Double] // x, y, z, w; meters; proper right-handed frames
    public init(position: [Double], quaternion: [Double]) {
        self.position = position; self.quaternion = quaternion
    }
    public var isValid: Bool {
        position.count == 3 && quaternion.count == 4
            && position.allSatisfy { $0.isFinite && abs($0) <= 100 }
            && quaternion.allSatisfy(\.isFinite)
            && abs(quaternion.reduce(0) { $0 + $1 * $1 } - 1) < 0.001
    }
}

public struct ROBShadowTrackingSample: Codable, Equatable, Sendable {
    public var trackingID: UUID
    public var sampleID: UInt64
    public var ageMilliseconds: Double
    public var quality: String
    public var pose: ROBShadowPose
    public init(trackingID: UUID, sampleID: UInt64, ageMilliseconds: Double,
                quality: String, pose: ROBShadowPose) {
        self.trackingID = trackingID; self.sampleID = sampleID
        self.ageMilliseconds = ageMilliseconds; self.quality = quality; self.pose = pose
    }
    public var isValid: Bool {
        sampleID > 0 && ageMilliseconds.isFinite && (0...60_000).contains(ageMilliseconds)
            && ["tracked", "low_accuracy", "unavailable"].contains(quality) && pose.isValid
    }
}

public struct ROBShadowCommand: Codable, Equatable, Sendable {
    public var action: ROBShadowAction
    public var shadowID: UUID
    public var requestID: UUID
    public var modelID: String?
    public var tracking: ROBShadowTrackingSample?
    public var translationScale: Double?
    public var delta: [Double]?
    public var arm: ROBShadowArm
    public var visionRequired: Bool?
    public init(_ action: ROBShadowAction, shadowID: UUID, modelID: String? = nil,
                tracking: ROBShadowTrackingSample? = nil, translationScale: Double? = nil,
                delta: [Double]? = nil, arm: ROBShadowArm = .left, visionRequired: Bool? = nil) {
        self.action = action; self.shadowID = shadowID; self.requestID = UUID(); self.modelID = modelID
        self.tracking = tracking; self.translationScale = translationScale; self.delta = delta
        self.arm = arm; self.visionRequired = action == .start ? (visionRequired ?? true) : visionRequired
    }
    public var isValid: Bool {
        if action == .start { return modelID == nil && tracking == nil && translationScale == nil && delta == nil && visionRequired != nil }
        guard visionRequired == nil else { return false }
        if action == .end && modelID == nil {
            return tracking == nil && translationScale == nil && delta == nil
        }
        guard let modelID, modelID.count == 64,
              modelID.allSatisfy({ "0123456789abcdef".contains($0) }) else { return false }
        if [.align, .clutch, .pose].contains(action) {
            guard tracking?.isValid == true, delta == nil else { return false }
        } else if tracking != nil { return false }
        if action == .clutch {
            guard translationScale == 0.2 || translationScale == 1 else { return false }
        } else if translationScale != nil { return false }
        if action == .nudge {
            return delta?.count == 3 && delta!.allSatisfy { $0.isFinite && abs($0) <= 0.01 }
                && delta!.filter({ $0 != 0 }).count == 1
        }
        return delta == nil
    }
}

public struct ROBShadowRequest: Codable, Equatable, Sendable {
    public var protocolName = ROBShadowProtocol.name
    public var kind = "request"
    public var controllerID: UUID
    public var sessionID: UUID
    public var sequence: UInt64
    public var sentAtMilliseconds: UInt64
    public var command: ROBShadowCommand
    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol", kind, controllerID, sessionID, sequence, sentAtMilliseconds, command
    }
    public init(controllerID: UUID, sessionID: UUID, sequence: UInt64,
                command: ROBShadowCommand, sentAtMilliseconds: UInt64 = ROBShadowProtocol.now()) {
        self.controllerID = controllerID; self.sessionID = sessionID; self.sequence = sequence
        self.sentAtMilliseconds = sentAtMilliseconds; self.command = command
    }
    public var isValid: Bool {
        protocolName == ROBShadowProtocol.name && kind == "request" && sequence > 0 && command.isValid
    }
}

public struct ROBShadowFrame: Codable, Equatable, Sendable {
    public var name: String
    public var pose: ROBShadowPose
}

public struct ROBShadowResponse: Codable, Equatable, Sendable {
    public var protocolName = ROBShadowProtocol.name
    public var kind = "response"
    public var controllerID: UUID
    public var sessionID: UUID
    public var sequence: UInt64 // echoes request; never a motor-command acknowledgement
    public var shadowID: UUID
    public var requestID: UUID
    public var modelID: String
    public var referenceID: String
    public var status: String
    public var detail: String
    public var hardwareOutputEnabled = false
    public var referenceSource = "approved_scan_estimate"
    public var collisionStatus = "not_checked"
    public var arm: ROBShadowArm = .left
    public var visionRequired = true
    public var visionStatus = "unavailable"
    public var visionDetail = "No live observation"
    public var visualAgeMilliseconds: Double?
    public var observedFrames: [ROBShadowFrame] = []
    public var clearanceMeters: Double?
    public var collisionPair: [String]?
    public var collisionDetail = "Clearance unavailable"
    public var frame = "base_link"
    public var referenceFrames: [ROBShadowFrame] = []
    public var ghostFrames: [ROBShadowFrame] = []
    public var positions: [Double] = [] // selected arm MODEL radians, never vendor coordinates
    public var target: ROBShadowPose?
    public var positionErrorMeters: Double?
    public var orientationErrorRadians: Double?
    public var solveMilliseconds: Double = 0
    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol", kind, controllerID, sessionID, sequence, shadowID, requestID,
             modelID, referenceID, status, detail, hardwareOutputEnabled, referenceSource,
             collisionStatus, frame, referenceFrames, ghostFrames, positions, target,
             positionErrorMeters, orientationErrorRadians, solveMilliseconds, arm, visionRequired,
             visionStatus, visionDetail, visualAgeMilliseconds, observedFrames, clearanceMeters, collisionPair, collisionDetail
    }
    public init(request: ROBShadowRequest, status: String, detail: String) {
        controllerID = request.controllerID; sessionID = request.sessionID; sequence = request.sequence
        shadowID = request.command.shadowID; requestID = request.command.requestID; modelID = request.command.modelID ?? ""
        referenceID = ""; self.status = status; self.detail = detail
        arm = request.command.arm
    }
    public var isValid: Bool {
        protocolName == ROBShadowProtocol.name && kind == "response" && sequence > 0
            && !hardwareOutputEnabled && referenceSource == "approved_scan_estimate"
            && ["not_checked", "clear_model", "blocked"].contains(collisionStatus) && frame == "base_link"
            && ["unavailable", "partial", "confirmed", "stale"].contains(visionStatus)
            && visionDetail.count <= 600 && collisionDetail.count <= 600
            && (visualAgeMilliseconds == nil || (visualAgeMilliseconds!.isFinite && visualAgeMilliseconds! >= 0))
            && (clearanceMeters == nil || clearanceMeters!.isFinite)
            && (collisionPair == nil || (collisionPair!.count == 2 && collisionPair!.allSatisfy { !$0.isEmpty && $0.count < 80 }))
            && ["ready", "aligned", "clutched", "solved", "paused", "blocked", "unavailable", "ended"].contains(status)
            && detail.count <= 1000 && (modelID.isEmpty || modelID.count == 64)
            && (referenceID.isEmpty || referenceID.count == 64)
            && referenceFrames.count <= 50 && ghostFrames.count <= 50 && observedFrames.count <= 50
            && [referenceFrames, ghostFrames, observedFrames].allSatisfy { frames in
                Set(frames.map(\.name)).count == frames.count
                    && frames.allSatisfy { !$0.name.isEmpty && $0.name.count < 80 && $0.pose.isValid }
            }
            && (positions.isEmpty || (positions.count == 7 && positions.allSatisfy { $0.isFinite && abs($0) <= Double.pi }))
            && (target == nil || target!.isValid)
            && [positionErrorMeters, orientationErrorRadians].allSatisfy { $0 == nil || ($0!.isFinite && $0! >= 0) }
            && solveMilliseconds.isFinite && solveMilliseconds >= 0
    }
}

public enum ROBShadowProtocol {
    public static let name = "rob-shadow-ik/2"
    public static let maximumBytes = 65_536
    public static func now() -> UInt64 { UInt64(max(0, Date().timeIntervalSince1970 * 1000)) }
    public static func fresh(_ request: ROBShadowRequest, now: UInt64 = now()) -> Bool {
        Double(now) - Double(request.sentAtMilliseconds) <= 500
            && Double(request.sentAtMilliseconds) - Double(now) <= 100
    }
    public static func claims(_ data: Data) -> Bool {
        // Claimed future versions and malformed shadow frames must never fall
        // through to Cerebro's historical motor-payload parser.
        if data.count <= maximumBytes,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = object["protocol"] as? String, name.hasPrefix("rob-shadow-ik/") { return true }
        return String(decoding: data.prefix(maximumBytes + 1), as: UTF8.self).contains("rob-shadow-ik/")
    }
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes else { throw Failure.invalid }
        return data
    }
    public static func request(_ data: Data) throws -> ROBShadowRequest {
        let value: ROBShadowRequest = try strictDecode(data)
        guard value.isValid else { throw Failure.invalid }; return value
    }
    public static func response(_ data: Data) throws -> ROBShadowResponse {
        let value: ROBShadowResponse = try strictDecode(data)
        guard value.isValid else { throw Failure.invalid }; return value
    }
    private static func strictDecode<T: Codable>(_ data: Data) throws -> T {
        guard data.count <= maximumBytes else { throw Failure.invalid }
        let value = try JSONDecoder().decode(T.self, from: data)
        let original = try JSONSerialization.jsonObject(with: data)
        let canonical = try JSONSerialization.jsonObject(with: encode(value))
        guard sameFields(original, canonical) else { throw Failure.invalid }
        return value
    }
    private static func sameFields(_ a: Any, _ b: Any) -> Bool {
        if let a = a as? [String: Any], let b = b as? [String: Any] {
            return Set(a.keys) == Set(b.keys) && a.allSatisfy { sameFields($0.value, b[$0.key]!) }
        }
        if let a = a as? [Any], let b = b as? [Any] {
            return a.count == b.count && zip(a, b).allSatisfy { sameFields($0, $1) }
        }
        return !(a is NSNull) && !(b is NSNull)
    }
    public enum Failure: Error { case invalid }
}
