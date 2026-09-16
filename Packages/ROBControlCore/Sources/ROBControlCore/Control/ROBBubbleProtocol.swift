import Foundation

// Kept byte-for-byte in Cerebro, ROBController, and ROBControlCore.
public enum ROBBubbleOperation: String, Codable, Sendable {
    case preview, heartbeat, authorize, authorizeMount, authorizeMotors, stop, stow, releaseMount, aim, manual
    case spinOn, spinOff, blowerOn, blowerOff, pulse, continuous, status
}

public struct ROBBubbleCommand: Codable, Equatable, Sendable {
    public var operation: ROBBubbleOperation
    public var frameID: UUID?
    /// RGB coordinates, top-left origin, normalized to the displayed image.
    public var u: Double?
    public var v: Double?
    public var pan: Int?
    public var tilt: Int?

    public init(_ operation: ROBBubbleOperation, frameID: UUID? = nil,
                u: Double? = nil, v: Double? = nil, pan: Int? = nil, tilt: Int? = nil) {
        self.operation = operation; self.frameID = frameID
        self.u = u; self.v = v; self.pan = pan; self.tilt = tilt
    }
}

public struct ROBBubbleStatus: Codable, Equatable, Sendable {
    public var detail: String
    public var armed: Bool
    public var dryRun: Bool
    public var spin: Bool
    public var blower: Bool
    public var spinReady: Bool
    public var mode: String
    public var remainingSeconds: Double
    public var cooldownSeconds: Double
    public var pan: Int
    public var tilt: Int
    public var targetDescription: String
    public var frameID: UUID?
    public var jpeg: Data?
    /// Optional for compatibility with older consoles. These modes are independent.
    public var mountLive: Bool?
    public var motorsLive: Bool?
    public var mountAuthorized: Bool?
    /// Ranging availability; the preview itself is always the face-camera RGB image.
    public var depthReady: Bool?

    public init(detail: String, armed: Bool, dryRun: Bool, spin: Bool, blower: Bool,
                spinReady: Bool, mode: String, remainingSeconds: Double,
                cooldownSeconds: Double, pan: Int, tilt: Int, targetDescription: String,
                frameID: UUID? = nil, jpeg: Data? = nil,
                mountLive: Bool? = nil, motorsLive: Bool? = nil, depthReady: Bool? = nil,
                mountAuthorized: Bool? = nil) {
        self.detail = detail; self.armed = armed; self.dryRun = dryRun
        self.spin = spin; self.blower = blower; self.spinReady = spinReady; self.mode = mode
        self.remainingSeconds = remainingSeconds; self.cooldownSeconds = cooldownSeconds
        self.pan = pan; self.tilt = tilt; self.targetDescription = targetDescription
        self.frameID = frameID; self.jpeg = jpeg
        self.mountLive = mountLive; self.motorsLive = motorsLive; self.depthReady = depthReady
        self.mountAuthorized = mountAuthorized
    }
}

public struct ROBBubbleMessage: Codable, Equatable, Sendable {
    public let controllerID: UUID
    public let sessionID: UUID
    public let sequence: UInt64
    public let sentAt: Double
    public let command: ROBBubbleCommand
    public let status: ROBBubbleStatus?

    public init(controllerID: UUID, sessionID: UUID, sequence: UInt64,
                sentAt: Double = Date().timeIntervalSince1970,
                command: ROBBubbleCommand, status: ROBBubbleStatus? = nil) {
        self.controllerID = controllerID; self.sessionID = sessionID
        self.sequence = sequence; self.sentAt = sentAt
        self.command = command; self.status = status
    }
}

public enum ROBBubbleProtocol {
    public static let maximumBytes = 524_288
    private static let magic = Data("ROBBUBBLE1".utf8)

    public static func claims(_ data: Data) -> Bool { data.starts(with: magic) }
    public static func encode(_ message: ROBBubbleMessage) throws -> Data {
        try validate(message)
        let data = magic + (try JSONEncoder().encode(message))
        guard data.count <= maximumBytes else { throw invalid("Message too large") }
        return data
    }
    public static func decode(_ data: Data) throws -> ROBBubbleMessage {
        guard claims(data), data.count <= maximumBytes else { throw invalid("Invalid envelope") }
        let message = try JSONDecoder().decode(ROBBubbleMessage.self, from: data.dropFirst(magic.count))
        try validate(message)
        return message
    }
    public static func isFresh(_ message: ROBBubbleMessage, now: Double) -> Bool {
        // Small positive clock skew is tolerated; replay protection also uses session + sequence.
        (-0.5 ... 2).contains(now - message.sentAt)
    }
    private static func invalid(_ detail: String) -> NSError {
        NSError(domain: "ROBBubbleProtocol", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }
    private static func validate(_ m: ROBBubbleMessage) throws {
        guard m.sequence > 0, m.sentAt.isFinite, m.sentAt > 0 else { throw invalid("Invalid identity") }
        let c = m.command
        if c.operation == .status {
            guard let s = m.status, s.detail.count <= 1024, s.targetDescription.count <= 512,
                  s.mode.count <= 32, (s.jpeg?.count ?? 0) <= 360_000,
                  s.remainingSeconds.isFinite, (0 ... 120).contains(s.remainingSeconds),
                  s.cooldownSeconds.isFinite, (0 ... 61).contains(s.cooldownSeconds),
                  (4000 ... 8000).contains(s.pan), (4000 ... 8000).contains(s.tilt),
                  (s.jpeg == nil) == (s.frameID == nil) else { throw invalid("Invalid status") }
        } else if m.status != nil { throw invalid("Controller supplied status") }
        switch c.operation {
        case .aim:
            guard c.frameID != nil, let u = c.u, let v = c.v,
                  u.isFinite, v.isFinite, (0 ... 1).contains(u), (0 ... 1).contains(v),
                  c.pan == nil, c.tilt == nil else { throw invalid("Invalid target pixel") }
        case .manual:
            guard let pan = c.pan, let tilt = c.tilt,
                  (4000 ... 8000).contains(pan), (4000 ... 8000).contains(tilt),
                  c.frameID == nil, c.u == nil, c.v == nil else { throw invalid("Invalid servo target") }
        default:
            guard c.frameID == nil, c.u == nil, c.v == nil, c.pan == nil, c.tilt == nil else {
                throw invalid("Unexpected command arguments")
            }
        }
    }
}
