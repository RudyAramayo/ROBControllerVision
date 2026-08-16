import Foundation

public struct RobotEndpointDescriptor: Codable, Hashable, Identifiable, Sendable {
    public enum Transport: String, Codable, Hashable, Sendable {
        case simulated
        case legacyUDP
        case quic
    }

    public let id: UUID
    public var name: String
    public var serviceType: String?
    public var transport: Transport

    public init(
        id: UUID = UUID(),
        name: String,
        serviceType: String? = nil,
        transport: Transport
    ) {
        self.id = id
        self.name = name
        self.serviceType = serviceType
        self.transport = transport
    }
}

public enum RobotConnectionPhase: String, Codable, Hashable, Sendable {
    case disconnected
    case connecting
    case handshaking
    case connected
    case disconnecting
    case failed
}

public struct ConnectionFailure: Codable, Error, Hashable, LocalizedError, Sendable {
    public enum Code: String, Codable, Hashable, Sendable {
        case cancelled
        case handshakeRejected
        case invalidState
        case transportUnavailable
        case unexpected
    }

    public let code: Code
    public let message: String
    public let isRecoverable: Bool

    public init(code: Code, message: String, isRecoverable: Bool = true) {
        self.code = code
        self.message = message
        self.isRecoverable = isRecoverable
    }

    public var errorDescription: String? { message }
}

public struct RobotCapabilities: Codable, Hashable, Sendable {
    public var supportsMotionControl: Bool
    public var supportsEmergencyStop: Bool
    public var supportsArmControlExecution: Bool
    public var cameras: [CameraDescriptor]

    public init(
        supportsMotionControl: Bool = true,
        supportsEmergencyStop: Bool = true,
        supportsArmControlExecution: Bool = false,
        cameras: [CameraDescriptor] = []
    ) {
        self.supportsMotionControl = supportsMotionControl
        self.supportsEmergencyStop = supportsEmergencyStop
        self.supportsArmControlExecution = supportsArmControlExecution
        self.cameras = cameras
    }
}

public struct RobotHandshake: Codable, Hashable, Sendable {
    public let protocolVersion: UInt16
    public let sessionID: UUID
    public let robotName: String
    public let connectedAtUnixMilliseconds: Int64
    public let capabilities: RobotCapabilities
    public let safetyState: MotionSafetyState

    public init(
        protocolVersion: UInt16 = 2,
        sessionID: UUID = UUID(),
        robotName: String,
        connectedAt: Date = Date(),
        capabilities: RobotCapabilities,
        safetyState: MotionSafetyState = MotionSafetyState()
    ) {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.robotName = robotName
        self.connectedAtUnixMilliseconds = Int64(
            (connectedAt.timeIntervalSince1970 * 1_000).rounded()
        )
        self.capabilities = capabilities
        self.safetyState = safetyState
    }

    public var connectedAt: Date {
        Date(timeIntervalSince1970: Double(connectedAtUnixMilliseconds) / 1_000)
    }
}

public struct RobotConnectionState: Codable, Hashable, Sendable {
    public var phase: RobotConnectionPhase
    public var endpoint: RobotEndpointDescriptor?
    public var handshake: RobotHandshake?
    public var failure: ConnectionFailure?

    public init(
        phase: RobotConnectionPhase,
        endpoint: RobotEndpointDescriptor? = nil,
        handshake: RobotHandshake? = nil,
        failure: ConnectionFailure? = nil
    ) {
        self.phase = phase
        self.endpoint = endpoint
        self.handshake = handshake
        self.failure = failure
    }

    public static let disconnected = RobotConnectionState(phase: .disconnected)

    public var isReady: Bool {
        phase == .connected && handshake != nil
    }
}

public struct RobotPose: Codable, Hashable, Sendable {
    public var xMeters: Double
    public var yMeters: Double
    public var headingRadians: Double

    public init(xMeters: Double = 0, yMeters: Double = 0, headingRadians: Double = 0) {
        self.xMeters = xMeters
        self.yMeters = yMeters
        self.headingRadians = headingRadians
    }
}

public struct RobotTelemetry: Codable, Hashable, Sendable {
    public var timestamp: Date
    public var batteryLevel: Double
    public var pose: RobotPose
    public var linearVelocity: Double
    public var angularVelocity: Double

    public init(
        timestamp: Date = Date(),
        batteryLevel: Double,
        pose: RobotPose,
        linearVelocity: Double,
        angularVelocity: Double
    ) {
        self.timestamp = timestamp
        self.batteryLevel = batteryLevel
        self.pose = pose
        self.linearVelocity = linearVelocity
        self.angularVelocity = angularVelocity
    }
}

public struct MotionSafetyState: Codable, Hashable, Sendable {
    public var isArmed: Bool
    public var emergencyStopIsLatched: Bool
    public var inhibitReason: MotionInhibitReason?
    public var lastCommandSequence: UInt64?

    public init(
        isArmed: Bool = false,
        emergencyStopIsLatched: Bool = false,
        inhibitReason: MotionInhibitReason? = .operatorDisarmed,
        lastCommandSequence: UInt64? = nil
    ) {
        self.isArmed = isArmed
        self.emergencyStopIsLatched = emergencyStopIsLatched
        self.inhibitReason = inhibitReason
        self.lastCommandSequence = lastCommandSequence
    }
}

public struct RobotSessionSnapshot: Equatable, Sendable {
    public var connection: RobotConnectionState
    public var safety: MotionSafetyState
    public var telemetry: RobotTelemetry?
    public var armTelemetry: RobotArmTelemetrySnapshot
    public var gripperTelemetry: RobotGripperTelemetrySnapshot
    public var robotActions: RobotActionApprovalSnapshot
    public var videoStreams: [VideoStreamDescriptor]

    public init(
        connection: RobotConnectionState = .disconnected,
        safety: MotionSafetyState = MotionSafetyState(),
        telemetry: RobotTelemetry? = nil,
        armTelemetry: RobotArmTelemetrySnapshot = RobotArmTelemetrySnapshot(),
        gripperTelemetry: RobotGripperTelemetrySnapshot = RobotGripperTelemetrySnapshot(),
        robotActions: RobotActionApprovalSnapshot = RobotActionApprovalSnapshot(),
        videoStreams: [VideoStreamDescriptor] = []
    ) {
        self.connection = connection
        self.safety = safety
        self.telemetry = telemetry
        self.armTelemetry = armTelemetry
        self.gripperTelemetry = gripperTelemetry
        self.robotActions = robotActions
        self.videoStreams = videoStreams
    }
}
