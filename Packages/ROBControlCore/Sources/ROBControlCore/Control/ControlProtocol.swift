import Foundation

public enum ControlInputSource: String, Codable, Hashable, Sendable {
    case gameController
    case spatialUI
    case testHarness
}

public struct MotionVector: Codable, Hashable, Sendable {
    public var linear: Float
    public var angular: Float

    public init(linear: Float, angular: Float) {
        self.linear = linear.isFinite ? max(-1, min(1, linear)) : 0
        self.angular = angular.isFinite ? max(-1, min(1, angular)) : 0
    }

    public static let stopped = MotionVector(linear: 0, angular: 0)

    public var isStopped: Bool {
        abs(linear) < 0.001 && abs(angular) < 0.001
    }

    private enum CodingKeys: String, CodingKey {
        case linear
        case angular
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            linear: try container.decode(Float.self, forKey: .linear),
            angular: try container.decode(Float.self, forKey: .angular)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(linear, forKey: .linear)
        try container.encode(angular, forKey: .angular)
    }
}

public struct CameraVector: Codable, Hashable, Sendable {
    public var pan: Float
    public var tilt: Float
    public var isActive: Bool

    public init(pan: Float = 0, tilt: Float = 0, isActive: Bool = false) {
        self.pan = pan.isFinite ? max(-1, min(1, pan)) : 0
        self.tilt = tilt.isFinite ? max(-1, min(1, tilt)) : 0
        self.isActive = isActive
    }

    public static let centered = CameraVector()
}

public struct GripperVector: Codable, Hashable, Sendable {
    public var leftClosed: Bool
    public var rightClosed: Bool
    public var isActive: Bool

    public init(leftClosed: Bool = false, rightClosed: Bool = false, isActive: Bool = false) {
        self.leftClosed = leftClosed
        self.rightClosed = rightClosed
        self.isActive = isActive
    }

    public static let inactive = GripperVector()
}

public struct OperatorControlSample: Equatable, Sendable {
    public let sequence: UInt64
    public let source: ControlInputSource
    public let motion: MotionVector
    public let cameraPan: Float
    public let cameraTilt: Float
    public let cameraControlIsActive: Bool
    public let leftGripperClosed: Bool
    public let rightGripperClosed: Bool
    public let deadManIsHeld: Bool
    public let controllerPoses: ControllerPosePair?

    public init(
        sequence: UInt64,
        source: ControlInputSource,
        linear: Float,
        angular: Float,
        cameraPan: Float = 0,
        cameraTilt: Float = 0,
        cameraControlIsActive: Bool = false,
        leftGripperClosed: Bool = false,
        rightGripperClosed: Bool = false,
        controllerPoses: ControllerPosePair? = nil,
        deadManIsHeld: Bool
    ) {
        self.sequence = sequence
        self.source = source
        self.motion = MotionVector(linear: linear, angular: angular)
        self.cameraPan = cameraPan.isFinite ? max(-1, min(1, cameraPan)) : 0
        self.cameraTilt = cameraTilt.isFinite ? max(-1, min(1, cameraTilt)) : 0
        self.cameraControlIsActive = cameraControlIsActive
        self.leftGripperClosed = leftGripperClosed
        self.rightGripperClosed = rightGripperClosed
        self.controllerPoses = controllerPoses
        self.deadManIsHeld = deadManIsHeld
    }
}

public struct ControllerPose: Codable, Equatable, Hashable, Sendable {
    public let x: Float
    public let y: Float
    public let z: Float
    public let qx: Float
    public let qy: Float
    public let qz: Float
    public let qw: Float
    public let timestamp: TimeInterval

    public init?(
        x: Float, y: Float, z: Float,
        qx: Float, qy: Float, qz: Float, qw: Float,
        timestamp: TimeInterval
    ) {
        let values = [x, y, z, qx, qy, qz, qw]
        guard values.allSatisfy(\.isFinite), timestamp.isFinite, timestamp >= 0 else { return nil }
        let quaternionMagnitude = sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
        guard quaternionMagnitude > 0.5, quaternionMagnitude < 1.5 else { return nil }
        self.x = x
        self.y = y
        self.z = z
        self.qx = qx / quaternionMagnitude
        self.qy = qy / quaternionMagnitude
        self.qz = qz / quaternionMagnitude
        self.qw = qw / quaternionMagnitude
        self.timestamp = timestamp
    }
}

public struct ControllerPosePair: Codable, Equatable, Hashable, Sendable {
    public let left: ControllerPose?
    public let right: ControllerPose?

    public init(left: ControllerPose? = nil, right: ControllerPose? = nil) {
        self.left = left
        self.right = right
    }

    public var isEmpty: Bool { left == nil && right == nil }
}

public enum MotionInhibitReason: String, Codable, Hashable, Sendable {
    case disconnected
    case operatorDisarmed
    case deadManReleased
    case inputExpired
    case sceneInactive
    case controllerDisconnected
    case emergencyStop
    case transportFailure
    case userRequested
    case robotWatchdog

    public var description: String {
        switch self {
        case .disconnected: "Robot disconnected"
        case .operatorDisarmed: "Motion disarmed"
        case .deadManReleased: "Dead-man control released"
        case .inputExpired: "Operator input expired"
        case .sceneInactive: "Application inactive"
        case .controllerDisconnected: "Controller disconnected"
        case .emergencyStop: "Emergency stop latched"
        case .transportFailure: "Transport failure"
        case .userRequested: "Stopped by operator"
        case .robotWatchdog: "Robot watchdog stopped motion"
        }
    }
}

public enum RobotCommand: Hashable, Sendable {
    case setArmed(Bool)
    case drive(
        MotionVector,
        CameraVector = .centered,
        GripperVector = .inactive,
        ControllerPosePair? = nil
    )
    case stop(MotionInhibitReason, ControllerPosePair? = nil)
    case emergencyStop
    case resetEmergencyStop
    case video(VideoControlMessage)
}

public struct RobotCommandEnvelope: Codable, Hashable, Identifiable, Sendable {
    public static let currentProtocolVersion: UInt16 = 2

    public let id: UUID
    public let protocolVersion: UInt16
    public let sessionID: UUID
    public let sequence: UInt64
    public let issuedAtUnixMilliseconds: Int64
    public let leaseMilliseconds: UInt32
    public let command: RobotCommand

    public init(
        id: UUID = UUID(),
        protocolVersion: UInt16 = RobotCommandEnvelope.currentProtocolVersion,
        sessionID: UUID,
        sequence: UInt64,
        issuedAt: Date = Date(),
        leaseMilliseconds: UInt32 = 250,
        command: RobotCommand
    ) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.sequence = sequence
        self.issuedAtUnixMilliseconds = Int64(
            (issuedAt.timeIntervalSince1970 * 1_000).rounded()
        )
        self.leaseMilliseconds = leaseMilliseconds
        self.command = command
    }

    public var issuedAt: Date {
        Date(timeIntervalSince1970: Double(issuedAtUnixMilliseconds) / 1_000)
    }
}

extension RobotCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case armed
        case motion
        case reason
        case video
        case controllerPoses
        case camera
        case grippers
    }

    private enum Kind: String, Codable {
        case setArmed
        case drive
        case stop
        case emergencyStop
        case resetEmergencyStop
        case video
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .setArmed:
            self = .setArmed(try container.decode(Bool.self, forKey: .armed))
        case .drive:
            self = .drive(
                try container.decode(MotionVector.self, forKey: .motion),
                try container.decodeIfPresent(CameraVector.self, forKey: .camera) ?? .centered,
                try container.decodeIfPresent(GripperVector.self, forKey: .grippers) ?? .inactive,
                try container.decodeIfPresent(ControllerPosePair.self, forKey: .controllerPoses)
            )
        case .stop:
            self = .stop(
                try container.decode(MotionInhibitReason.self, forKey: .reason),
                try container.decodeIfPresent(ControllerPosePair.self, forKey: .controllerPoses)
            )
        case .emergencyStop:
            self = .emergencyStop
        case .resetEmergencyStop:
            self = .resetEmergencyStop
        case .video:
            self = .video(try container.decode(VideoControlMessage.self, forKey: .video))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setArmed(let armed):
            try container.encode(Kind.setArmed, forKey: .type)
            try container.encode(armed, forKey: .armed)
        case .drive(let motion, let camera, let grippers, let controllerPoses):
            try container.encode(Kind.drive, forKey: .type)
            try container.encode(motion, forKey: .motion)
            try container.encode(camera, forKey: .camera)
            try container.encode(grippers, forKey: .grippers)
            try container.encodeIfPresent(controllerPoses, forKey: .controllerPoses)
        case .stop(let reason, let controllerPoses):
            try container.encode(Kind.stop, forKey: .type)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(controllerPoses, forKey: .controllerPoses)
        case .emergencyStop:
            try container.encode(Kind.emergencyStop, forKey: .type)
        case .resetEmergencyStop:
            try container.encode(Kind.resetEmergencyStop, forKey: .type)
        case .video(let video):
            try container.encode(Kind.video, forKey: .type)
            try container.encode(video, forKey: .video)
        }
    }
}

public enum RobotSafetyEvent: Equatable, Sendable {
    case motionStopped(MotionInhibitReason)
    case armedChanged(Bool)
    case emergencyStopChanged(Bool)
}

public enum RobotEvent: Equatable, Sendable {
    case connected(RobotHandshake)
    case disconnected(reason: String)
    case telemetry(RobotTelemetry)
    case commandAcknowledged(UUID)
    case safety(RobotSafetyEvent)
    case video(VideoEvent)
}

public enum RobotTransportError: Error, Equatable, LocalizedError, Sendable {
    case alreadyConnected
    case notConnected
    case commandExpired
    case staleCommand
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyConnected: "The transport is already connected."
        case .notConnected: "The transport is not connected."
        case .commandExpired: "The command lease has expired."
        case .staleCommand: "The command sequence is stale."
        case .invalidState(let detail): detail
        }
    }
}

public protocol RobotTransport: Sendable {
    var descriptor: RobotEndpointDescriptor { get }

    func connect() async throws -> RobotHandshake
    func disconnect() async
    func send(_ envelope: RobotCommandEnvelope) async throws
    func events() async -> AsyncStream<RobotEvent>
}
