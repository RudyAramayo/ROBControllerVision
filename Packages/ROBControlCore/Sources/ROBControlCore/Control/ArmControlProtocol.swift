import Foundation

public enum RobotArmSide: String, Codable, CaseIterable, Hashable, Sendable {
    case left
    case right
}

public enum RobotArmTargetSource: String, Codable, CaseIterable, Hashable, Sendable {
    case visionProSpatial = "vision_pro_spatial"
    case visionProJointUI = "vision_pro_joint_ui"
    case testHarness = "test_harness"
}

public struct RobotArmTargetIntent: Codable, Hashable, Sendable {
    public static let jointCount = 7
    /// Calibrated Amber B1 J1...J7 bounds. Cerebro and the gateway enforce
    /// the same ordered values; Vision rejects an invalid intent before I/O.
    public static let jointBoundsRadians: [ClosedRange<Double>] = [
        -2.4435 ... 2.4435,
        -2.3213 ... 2.3213,
        -2.2863 ... 2.2863,
        -2.2863 ... 2.2863,
        -2.2863 ... 2.2863,
        -2.2863 ... 2.2863,
        -3.05 ... 3.05,
    ]

    public let arm: RobotArmSide
    public let source: RobotArmTargetSource
    public let positionsRadians: [Double]
    public let durationSeconds: Double

    public static func containsPositions(_ positionsRadians: [Double]) -> Bool {
        positionsRadians.count == jointBoundsRadians.count
            && zip(positionsRadians, jointBoundsRadians).allSatisfy { position, bounds in
                position.isFinite && bounds.contains(position)
            }
    }

    public init?(
        arm: RobotArmSide,
        source: RobotArmTargetSource,
        positionsRadians: [Double],
        durationSeconds: Double
    ) {
        guard Self.containsPositions(positionsRadians),
            durationSeconds.isFinite,
            (0.65 ... 10).contains(durationSeconds)
        else { return nil }
        self.arm = arm
        self.source = source
        self.positionsRadians = positionsRadians
        self.durationSeconds = durationSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case arm, source
        case positionsRadians = "positions_rad"
        case durationSeconds = "duration_s"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self.init(
            arm: try container.decode(RobotArmSide.self, forKey: .arm),
            source: try container.decode(RobotArmTargetSource.self, forKey: .source),
            positionsRadians: try container.decode([Double].self, forKey: .positionsRadians),
            durationSeconds: try container.decode(Double.self, forKey: .durationSeconds)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .positionsRadians,
                in: container,
                debugDescription: "Arm target exceeds the seven-joint position or duration bounds."
            )
        }
        self = value
    }
}

public struct RobotArmMeasuredState: Codable, Hashable, Sendable {
    public let messageID: UUID
    public let arm: RobotArmSide
    public let sequence: UInt64
    public let sampledAtUnixMilliseconds: Int64
    public let sampleAgeMilliseconds: Double
    public let positionsRadians: [Double]
    public let velocitiesRadiansPerSecond: [Double]
    public let currents: [Double]
    public let statuses: [Double]
    public let modes: [Int]

    public init?(
        messageID: UUID = UUID(),
        arm: RobotArmSide,
        sequence: UInt64,
        sampledAtUnixMilliseconds: Int64,
        sampleAgeMilliseconds: Double,
        positionsRadians: [Double],
        velocitiesRadiansPerSecond: [Double],
        currents: [Double],
        statuses: [Double],
        modes: [Int]
    ) {
        guard sequence > 0,
            sampledAtUnixMilliseconds > 0,
            sampleAgeMilliseconds.isFinite,
            (0 ... 60_000).contains(sampleAgeMilliseconds),
            Self.validVector(positionsRadians, absoluteLimit: 4 * .pi),
            Self.validVector(velocitiesRadiansPerSecond, absoluteLimit: 100),
            Self.validVector(currents, absoluteLimit: 1_000),
            Self.validVector(statuses, absoluteLimit: 1_000_000_000),
            modes.count == RobotArmTargetIntent.jointCount
        else { return nil }
        self.messageID = messageID
        self.arm = arm
        self.sequence = sequence
        self.sampledAtUnixMilliseconds = sampledAtUnixMilliseconds
        self.sampleAgeMilliseconds = sampleAgeMilliseconds
        self.positionsRadians = positionsRadians
        self.velocitiesRadiansPerSecond = velocitiesRadiansPerSecond
        self.currents = currents
        self.statuses = statuses
        self.modes = modes
    }

    public var sampledAt: Date {
        Date(timeIntervalSince1970: Double(sampledAtUnixMilliseconds) / 1_000)
    }

    private static func validVector(_ vector: [Double], absoluteLimit: Double) -> Bool {
        vector.count == RobotArmTargetIntent.jointCount
            && vector.allSatisfy { $0.isFinite && abs($0) <= absoluteLimit }
    }

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case arm, sequence
        case sampledAtUnixMilliseconds = "sampled_at_unix_ms"
        case sampleAgeMilliseconds = "sample_age_ms"
        case positionsRadians = "positions_rad"
        case velocitiesRadiansPerSecond = "velocities_rad_s"
        case currents, statuses, modes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self.init(
            messageID: try container.decode(UUID.self, forKey: .messageID),
            arm: try container.decode(RobotArmSide.self, forKey: .arm),
            sequence: try container.decode(UInt64.self, forKey: .sequence),
            sampledAtUnixMilliseconds: try container.decode(
                Int64.self,
                forKey: .sampledAtUnixMilliseconds
            ),
            sampleAgeMilliseconds: try container.decode(
                Double.self,
                forKey: .sampleAgeMilliseconds
            ),
            positionsRadians: try container.decode([Double].self, forKey: .positionsRadians),
            velocitiesRadiansPerSecond: try container.decode(
                [Double].self,
                forKey: .velocitiesRadiansPerSecond
            ),
            currents: try container.decode([Double].self, forKey: .currents),
            statuses: try container.decode([Double].self, forKey: .statuses),
            modes: try container.decode([Int].self, forKey: .modes)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .positionsRadians,
                in: container,
                debugDescription: "Measured arm state exceeded protocol bounds."
            )
        }
        self = value
    }
}

public enum RobotArmTargetDispositionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case acceptedForExecution = "accepted_for_execution"
    case executing
    case completedMeasured = "completed_measured"
    case cancelledHeld = "cancelled_held"
    case leaseExpiredHeld = "lease_expired_held"
    case holdConfirmed = "hold_confirmed"
    case holdUnconfirmed = "hold_unconfirmed"
    case failed
    case rejectedAuthorityDisabled = "rejected_authority_disabled"
    case rejectedExpired = "rejected_expired"
    case rejectedIdentityMismatch = "rejected_identity_mismatch"
    case rejectedSessionInactive = "rejected_session_inactive"
    case rejectedStaleSequence = "rejected_stale_sequence"
    case rejectedTelemetryStale = "rejected_telemetry_stale"
    case rejectedPositionModeRequired = "rejected_position_mode_required"
    case rejectedStepLimit = "rejected_step_limit"
    case rejectedSpeedLimit = "rejected_speed_limit"
    case rejectedArmBusy = "rejected_arm_busy"
    case rejectedInvalid = "rejected_invalid"

    public var executionEligible: Bool {
        switch self {
        case .acceptedForExecution, .executing, .completedMeasured:
            true
        default:
            false
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .acceptedForExecution, .executing:
            false
        default:
            true
        }
    }
}

public struct RobotArmTargetDisposition: Codable, Hashable, Sendable {
    public let messageID: UUID
    public let targetMessageID: UUID
    public let recipientID: UUID
    public let sessionID: UUID
    public let arm: RobotArmSide
    public let receivedAtUnixMilliseconds: Int64
    public let disposition: RobotArmTargetDispositionKind
    public let executionEligible: Bool
    public let terminal: Bool
    public let detail: String
    public let measuredPositionsRadians: [Double]?
    public let maximumErrorRadians: Double?

    public init?(
        messageID: UUID = UUID(),
        targetMessageID: UUID,
        recipientID: UUID,
        sessionID: UUID,
        arm: RobotArmSide,
        receivedAtUnixMilliseconds: Int64,
        disposition: RobotArmTargetDispositionKind,
        executionEligible: Bool,
        terminal: Bool,
        detail: String,
        measuredPositionsRadians: [Double]? = nil,
        maximumErrorRadians: Double? = nil
    ) {
        guard receivedAtUnixMilliseconds > 0,
            executionEligible == disposition.executionEligible,
            terminal == disposition.isTerminal,
            !detail.isEmpty,
            detail.count <= 256,
            measuredPositionsRadians.map({
                $0.count == RobotArmTargetIntent.jointCount
                    && $0.allSatisfy { $0.isFinite && abs($0) <= 4 * .pi }
            }) ?? true,
            maximumErrorRadians.map({ $0.isFinite && $0 >= 0 }) ?? true
        else { return nil }
        self.messageID = messageID
        self.targetMessageID = targetMessageID
        self.recipientID = recipientID
        self.sessionID = sessionID
        self.arm = arm
        self.receivedAtUnixMilliseconds = receivedAtUnixMilliseconds
        self.disposition = disposition
        self.executionEligible = executionEligible
        self.terminal = terminal
        self.detail = detail
        self.measuredPositionsRadians = measuredPositionsRadians
        self.maximumErrorRadians = maximumErrorRadians
    }

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case targetMessageID = "target_message_id"
        case recipientID = "recipient_id"
        case sessionID = "session_id"
        case arm
        case receivedAtUnixMilliseconds = "received_at_unix_ms"
        case disposition
        case executionEligible = "execution_eligible"
        case terminal, detail
        case measuredPositionsRadians = "measured_positions_rad"
        case maximumErrorRadians = "max_error_rad"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self.init(
            messageID: try container.decode(UUID.self, forKey: .messageID),
            targetMessageID: try container.decode(UUID.self, forKey: .targetMessageID),
            recipientID: try container.decode(UUID.self, forKey: .recipientID),
            sessionID: try container.decode(UUID.self, forKey: .sessionID),
            arm: try container.decode(RobotArmSide.self, forKey: .arm),
            receivedAtUnixMilliseconds: try container.decode(
                Int64.self,
                forKey: .receivedAtUnixMilliseconds
            ),
            disposition: try container.decode(
                RobotArmTargetDispositionKind.self,
                forKey: .disposition
            ),
            executionEligible: try container.decode(Bool.self, forKey: .executionEligible),
            terminal: try container.decode(Bool.self, forKey: .terminal),
            detail: try container.decode(String.self, forKey: .detail),
            measuredPositionsRadians: try container.decodeIfPresent(
                [Double].self,
                forKey: .measuredPositionsRadians
            ),
            maximumErrorRadians: try container.decodeIfPresent(
                Double.self,
                forKey: .maximumErrorRadians
            )
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .executionEligible,
                in: container,
                debugDescription: "Arm disposition flags or measured feedback were inconsistent."
            )
        }
        self = value
    }
}

public enum RobotArmAuthorityOperation: String, Codable, CaseIterable, Hashable, Sendable {
    case acquire
    case release
}

public enum RobotArmAuthorityStateKind: String, Codable, CaseIterable, Hashable, Sendable {
    case granted
    case released
    case rejected
    case expired
}

public struct RobotArmAuthorityState: Codable, Hashable, Sendable {
    public let messageID: UUID
    public let requestMessageID: UUID
    public let recipientID: UUID
    public let sessionID: UUID
    public let arm: RobotArmSide
    public let state: RobotArmAuthorityStateKind
    public let authorityID: UUID?
    public let expiresAtUnixMilliseconds: Int64
    public let detail: String
    public let baselinePositionsRadians: [Double]
    public let baselineSequence: UInt64
    public let modes: [Int]

    public init?(
        messageID: UUID = UUID(),
        requestMessageID: UUID,
        recipientID: UUID,
        sessionID: UUID,
        arm: RobotArmSide,
        state: RobotArmAuthorityStateKind,
        authorityID: UUID?,
        expiresAtUnixMilliseconds: Int64,
        detail: String,
        baselinePositionsRadians: [Double],
        baselineSequence: UInt64,
        modes: [Int]
    ) {
        let hasValidBaseline = RobotArmTargetIntent.containsPositions(baselinePositionsRadians)
        guard expiresAtUnixMilliseconds >= 0,
            !detail.isEmpty,
            detail.count <= 256,
            baselinePositionsRadians.isEmpty || hasValidBaseline,
            modes.isEmpty || modes.count == RobotArmTargetIntent.jointCount
        else { return nil }
        if state == .granted {
            guard authorityID != nil,
                expiresAtUnixMilliseconds > 0,
                hasValidBaseline,
                baselineSequence > 0,
                modes.count == RobotArmTargetIntent.jointCount
            else { return nil }
        }
        self.messageID = messageID
        self.requestMessageID = requestMessageID
        self.recipientID = recipientID
        self.sessionID = sessionID
        self.arm = arm
        self.state = state
        self.authorityID = authorityID
        self.expiresAtUnixMilliseconds = expiresAtUnixMilliseconds
        self.detail = detail
        self.baselinePositionsRadians = baselinePositionsRadians
        self.baselineSequence = baselineSequence
        self.modes = modes
    }

    public var expiresAt: Date {
        Date(timeIntervalSince1970: Double(expiresAtUnixMilliseconds) / 1_000)
    }

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case requestMessageID = "request_message_id"
        case recipientID = "recipient_id"
        case sessionID = "session_id"
        case arm, state
        case authorityID = "authority_id"
        case expiresAtUnixMilliseconds = "expires_at_unix_ms"
        case detail
        case baselinePositionsRadians = "baseline_positions_rad"
        case baselineSequence = "baseline_sequence"
        case modes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self.init(
            messageID: try container.decode(UUID.self, forKey: .messageID),
            requestMessageID: try container.decode(UUID.self, forKey: .requestMessageID),
            recipientID: try container.decode(UUID.self, forKey: .recipientID),
            sessionID: try container.decode(UUID.self, forKey: .sessionID),
            arm: try container.decode(RobotArmSide.self, forKey: .arm),
            state: try container.decode(RobotArmAuthorityStateKind.self, forKey: .state),
            authorityID: try container.decodeIfPresent(UUID.self, forKey: .authorityID),
            expiresAtUnixMilliseconds: try container.decode(
                Int64.self,
                forKey: .expiresAtUnixMilliseconds
            ),
            detail: try container.decode(String.self, forKey: .detail),
            baselinePositionsRadians: try container.decode(
                [Double].self,
                forKey: .baselinePositionsRadians
            ),
            baselineSequence: try container.decode(UInt64.self, forKey: .baselineSequence),
            modes: try container.decode([Int].self, forKey: .modes)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .state,
                in: container,
                debugDescription: "Arm authority state was internally inconsistent."
            )
        }
        self = value
    }
}

public struct RobotArmTargetIntentWireMessage: Codable, Hashable, Sendable {
    public let messageID: UUID
    public let senderID: UUID
    public let sessionID: UUID
    public let sequence: UInt64
    public let issuedAtUnixMilliseconds: Int64
    public let leaseMilliseconds: UInt32
    public let authorityID: UUID
    public let deadManIsHeld: Bool
    public let target: RobotArmTargetIntent

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case senderID = "sender_id"
        case sessionID = "session_id"
        case sequence
        case issuedAtUnixMilliseconds = "issued_at_unix_ms"
        case leaseMilliseconds = "lease_ms"
        case authorityID = "authority_id"
        case deadManIsHeld = "dead_man_held"
        case arm, source
        case positionsRadians = "positions_rad"
        case durationSeconds = "duration_s"
    }

    public init(
        messageID: UUID,
        senderID: UUID,
        sessionID: UUID,
        sequence: UInt64,
        issuedAtUnixMilliseconds: Int64,
        leaseMilliseconds: UInt32,
        authorityID: UUID,
        deadManIsHeld: Bool,
        target: RobotArmTargetIntent
    ) {
        self.messageID = messageID
        self.senderID = senderID
        self.sessionID = sessionID
        self.sequence = sequence
        self.issuedAtUnixMilliseconds = issuedAtUnixMilliseconds
        self.leaseMilliseconds = leaseMilliseconds
        self.authorityID = authorityID
        self.deadManIsHeld = deadManIsHeld
        self.target = target
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let target = RobotArmTargetIntent(
            arm: try container.decode(RobotArmSide.self, forKey: .arm),
            source: try container.decode(RobotArmTargetSource.self, forKey: .source),
            positionsRadians: try container.decode([Double].self, forKey: .positionsRadians),
            durationSeconds: try container.decode(Double.self, forKey: .durationSeconds)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .positionsRadians,
                in: container,
                debugDescription: "Arm target exceeded protocol bounds."
            )
        }
        messageID = try container.decode(UUID.self, forKey: .messageID)
        senderID = try container.decode(UUID.self, forKey: .senderID)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        issuedAtUnixMilliseconds = try container.decode(
            Int64.self,
            forKey: .issuedAtUnixMilliseconds
        )
        leaseMilliseconds = try container.decode(UInt32.self, forKey: .leaseMilliseconds)
        authorityID = try container.decode(UUID.self, forKey: .authorityID)
        deadManIsHeld = try container.decode(Bool.self, forKey: .deadManIsHeld)
        self.target = target
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(messageID, forKey: .messageID)
        try container.encode(senderID, forKey: .senderID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(issuedAtUnixMilliseconds, forKey: .issuedAtUnixMilliseconds)
        try container.encode(leaseMilliseconds, forKey: .leaseMilliseconds)
        try container.encode(authorityID, forKey: .authorityID)
        try container.encode(deadManIsHeld, forKey: .deadManIsHeld)
        try container.encode(target.arm, forKey: .arm)
        try container.encode(target.source, forKey: .source)
        try container.encode(target.positionsRadians, forKey: .positionsRadians)
        try container.encode(target.durationSeconds, forKey: .durationSeconds)
    }
}

public struct RobotArmAuthorityIntentWireMessage: Codable, Hashable, Sendable {
    public let messageID: UUID
    public let senderID: UUID
    public let sessionID: UUID
    public let sequence: UInt64
    public let issuedAtUnixMilliseconds: Int64
    public let leaseMilliseconds: UInt32
    public let arm: RobotArmSide
    public let operation: RobotArmAuthorityOperation

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case senderID = "sender_id"
        case sessionID = "session_id"
        case sequence
        case issuedAtUnixMilliseconds = "issued_at_unix_ms"
        case leaseMilliseconds = "lease_ms"
        case arm, operation
    }
}

public struct RobotArmHoldIntentWireMessage: Codable, Hashable, Sendable {
    public let messageID: UUID
    public let senderID: UUID
    public let sessionID: UUID
    public let sequence: UInt64
    public let issuedAtUnixMilliseconds: Int64
    public let leaseMilliseconds: UInt32
    public let arm: RobotArmSide
    public let authorityID: UUID?
    public let reason: String

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case senderID = "sender_id"
        case sessionID = "session_id"
        case sequence
        case issuedAtUnixMilliseconds = "issued_at_unix_ms"
        case leaseMilliseconds = "lease_ms"
        case arm
        case authorityID = "authority_id"
        case reason
    }
}

public enum RobotArmWireDecodedMessage: Hashable, Sendable {
    case measuredState(RobotArmMeasuredState)
    case targetIntent(RobotArmTargetIntentWireMessage)
    case authorityIntent(RobotArmAuthorityIntentWireMessage)
    case authorityState(RobotArmAuthorityState)
    case holdIntent(RobotArmHoldIntentWireMessage)
    case targetDisposition(RobotArmTargetDisposition)
}

public enum RobotArmWireError: Error, Equatable, Sendable {
    case oversized
    case malformed
    case unknownType
    case unexpectedFields
    case invalid(String)
}

public enum RobotArmWireCodec {
    public static let protocolName = "rob-arm-control/2"
    public static let schemaVersion = 2
    public static let maximumMessageBytes = 8 * 1_024

    private struct WireEnvelope<T: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
        let protocolName: String
        let schemaVersion: Int
        let type: String
        let payload: T

        enum CodingKeys: String, CodingKey {
            case protocolName = "protocol"
            case schemaVersion = "schema_version"
            case type
        }

        init(type: String, payload: T) {
            protocolName = RobotArmWireCodec.protocolName
            schemaVersion = RobotArmWireCodec.schemaVersion
            self.type = type
            self.payload = payload
        }

        init(from decoder: any Decoder) throws {
            let header = try decoder.container(keyedBy: CodingKeys.self)
            protocolName = try header.decode(String.self, forKey: .protocolName)
            schemaVersion = try header.decode(Int.self, forKey: .schemaVersion)
            type = try header.decode(String.self, forKey: .type)
            payload = try T(from: decoder)
        }

        func encode(to encoder: any Encoder) throws {
            var header = encoder.container(keyedBy: CodingKeys.self)
            try header.encode(protocolName, forKey: .protocolName)
            try header.encode(schemaVersion, forKey: .schemaVersion)
            try header.encode(type, forKey: .type)
            try payload.encode(to: encoder)
        }
    }

    private static let measuredKeys: Set<String> = [
        "protocol", "schema_version", "type", "message_id", "arm", "sequence",
        "sampled_at_unix_ms", "sample_age_ms", "positions_rad", "velocities_rad_s",
        "currents", "statuses", "modes",
    ]
    private static let targetKeys: Set<String> = [
        "protocol", "schema_version", "type", "message_id", "sender_id", "session_id",
        "sequence", "issued_at_unix_ms", "lease_ms", "arm", "source", "positions_rad",
        "duration_s", "authority_id", "dead_man_held",
    ]
    private static let authorityIntentKeys: Set<String> = [
        "protocol", "schema_version", "type", "message_id", "sender_id", "session_id",
        "sequence", "issued_at_unix_ms", "lease_ms", "arm", "operation",
    ]
    private static let authorityStateKeys: Set<String> = [
        "protocol", "schema_version", "type", "message_id", "request_message_id",
        "recipient_id", "session_id", "arm", "state", "authority_id",
        "expires_at_unix_ms", "detail", "baseline_positions_rad", "baseline_sequence",
        "modes",
    ]
    private static let holdIntentKeys: Set<String> = [
        "protocol", "schema_version", "type", "message_id", "sender_id", "session_id",
        "sequence", "issued_at_unix_ms", "lease_ms", "arm", "authority_id", "reason",
    ]
    private static let dispositionKeys: Set<String> = [
        "protocol", "schema_version", "type", "message_id", "target_message_id",
        "recipient_id", "session_id", "arm", "received_at_unix_ms", "disposition",
        "execution_eligible", "terminal", "detail", "measured_positions_rad", "max_error_rad",
    ]

    /// Returns nil for unrelated ROBControl application data.
    public static func decode(
        _ data: Data,
        nowUnixMilliseconds: Int64? = nil
    ) throws -> RobotArmWireDecodedMessage? {
        guard !data.isEmpty else { return nil }
        guard data.count <= maximumMessageBytes else { throw RobotArmWireError.oversized }
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else { return nil }
        guard dictionary["protocol"] as? String == protocolName else { return nil }
        guard dictionary["schema_version"] as? Int == schemaVersion,
            let type = dictionary["type"] as? String
        else { throw RobotArmWireError.malformed }

        let decoder = JSONDecoder()
        do {
            switch type {
            case "measured_state":
                guard Set(dictionary.keys) == measuredKeys else {
                    throw RobotArmWireError.unexpectedFields
                }
                let envelope = try decoder.decode(
                    WireEnvelope<RobotArmMeasuredState>.self,
                    from: data
                )
                return .measuredState(envelope.payload)
            case "target_intent":
                guard Set(dictionary.keys) == targetKeys else {
                    throw RobotArmWireError.unexpectedFields
                }
                let envelope = try decoder.decode(
                    WireEnvelope<RobotArmTargetIntentWireMessage>.self,
                    from: data
                )
                try validateTargetWire(
                    envelope.payload,
                    nowUnixMilliseconds: nowUnixMilliseconds ?? currentUnixMilliseconds()
                )
                return .targetIntent(envelope.payload)
            case "authority_intent":
                guard Set(dictionary.keys) == authorityIntentKeys else {
                    throw RobotArmWireError.unexpectedFields
                }
                let envelope = try decoder.decode(
                    WireEnvelope<RobotArmAuthorityIntentWireMessage>.self,
                    from: data
                )
                try validateAuthorityWire(
                    envelope.payload,
                    nowUnixMilliseconds: nowUnixMilliseconds ?? currentUnixMilliseconds()
                )
                return .authorityIntent(envelope.payload)
            case "authority_state":
                guard Set(dictionary.keys).isSubset(of: authorityStateKeys),
                    authorityStateKeys.subtracting(["authority_id"]).isSubset(of: dictionary.keys)
                else { throw RobotArmWireError.unexpectedFields }
                let envelope = try decoder.decode(
                    WireEnvelope<RobotArmAuthorityState>.self,
                    from: data
                )
                return .authorityState(envelope.payload)
            case "hold_intent":
                guard Set(dictionary.keys).isSubset(of: holdIntentKeys),
                    holdIntentKeys.subtracting(["authority_id"]).isSubset(of: dictionary.keys)
                else { throw RobotArmWireError.unexpectedFields }
                let envelope = try decoder.decode(
                    WireEnvelope<RobotArmHoldIntentWireMessage>.self,
                    from: data
                )
                try validateHoldWire(
                    envelope.payload,
                    nowUnixMilliseconds: nowUnixMilliseconds ?? currentUnixMilliseconds()
                )
                return .holdIntent(envelope.payload)
            case "target_disposition":
                let optionalDispositionKeys: Set<String> = [
                    "measured_positions_rad", "max_error_rad",
                ]
                guard Set(dictionary.keys).isSubset(of: dispositionKeys),
                    dispositionKeys.subtracting(optionalDispositionKeys).isSubset(of: dictionary.keys)
                else {
                    throw RobotArmWireError.unexpectedFields
                }
                let envelope = try decoder.decode(
                    WireEnvelope<RobotArmTargetDisposition>.self,
                    from: data
                )
                return .targetDisposition(envelope.payload)
            default:
                throw RobotArmWireError.unknownType
            }
        } catch let error as RobotArmWireError {
            throw error
        } catch {
            throw RobotArmWireError.malformed
        }
    }

    public static func encodeTargetIntent(
        _ target: RobotArmTargetIntent,
        messageID: UUID,
        senderID: UUID,
        sessionID: UUID,
        sequence: UInt64,
        issuedAtUnixMilliseconds: Int64,
        leaseMilliseconds: UInt32,
        authorityID: UUID,
        deadManIsHeld: Bool,
        nowUnixMilliseconds: Int64? = nil
    ) throws -> Data {
        let message = RobotArmTargetIntentWireMessage(
            messageID: messageID,
            senderID: senderID,
            sessionID: sessionID,
            sequence: sequence,
            issuedAtUnixMilliseconds: issuedAtUnixMilliseconds,
            leaseMilliseconds: leaseMilliseconds,
            authorityID: authorityID,
            deadManIsHeld: deadManIsHeld,
            target: target
        )
        try validateTargetWire(
            message,
            nowUnixMilliseconds: nowUnixMilliseconds ?? currentUnixMilliseconds()
        )
        return try encodeBounded(WireEnvelope(type: "target_intent", payload: message))
    }

    public static func encodeAuthorityIntent(
        arm: RobotArmSide,
        operation: RobotArmAuthorityOperation,
        messageID: UUID,
        senderID: UUID,
        sessionID: UUID,
        sequence: UInt64,
        issuedAtUnixMilliseconds: Int64,
        leaseMilliseconds: UInt32,
        nowUnixMilliseconds: Int64? = nil
    ) throws -> Data {
        let message = RobotArmAuthorityIntentWireMessage(
            messageID: messageID,
            senderID: senderID,
            sessionID: sessionID,
            sequence: sequence,
            issuedAtUnixMilliseconds: issuedAtUnixMilliseconds,
            leaseMilliseconds: leaseMilliseconds,
            arm: arm,
            operation: operation
        )
        try validateAuthorityWire(
            message,
            nowUnixMilliseconds: nowUnixMilliseconds ?? currentUnixMilliseconds()
        )
        return try encodeBounded(WireEnvelope(type: "authority_intent", payload: message))
    }

    public static func encodeHoldIntent(
        arm: RobotArmSide,
        authorityID: UUID?,
        reason: String,
        messageID: UUID,
        senderID: UUID,
        sessionID: UUID,
        sequence: UInt64,
        issuedAtUnixMilliseconds: Int64,
        leaseMilliseconds: UInt32,
        nowUnixMilliseconds: Int64? = nil
    ) throws -> Data {
        let message = RobotArmHoldIntentWireMessage(
            messageID: messageID,
            senderID: senderID,
            sessionID: sessionID,
            sequence: sequence,
            issuedAtUnixMilliseconds: issuedAtUnixMilliseconds,
            leaseMilliseconds: leaseMilliseconds,
            arm: arm,
            authorityID: authorityID,
            reason: reason
        )
        try validateHoldWire(
            message,
            nowUnixMilliseconds: nowUnixMilliseconds ?? currentUnixMilliseconds()
        )
        return try encodeBounded(WireEnvelope(type: "hold_intent", payload: message))
    }

    public static func encodeMeasuredState(_ state: RobotArmMeasuredState) throws -> Data {
        try encodeBounded(WireEnvelope(type: "measured_state", payload: state))
    }

    public static func encodeAuthorityState(_ state: RobotArmAuthorityState) throws -> Data {
        try encodeBounded(WireEnvelope(type: "authority_state", payload: state))
    }

    public static func encodeTargetDisposition(
        _ disposition: RobotArmTargetDisposition
    ) throws -> Data {
        try encodeBounded(WireEnvelope(type: "target_disposition", payload: disposition))
    }

    private static func validateTargetWire(
        _ message: RobotArmTargetIntentWireMessage,
        nowUnixMilliseconds: Int64 = currentUnixMilliseconds()
    ) throws {
        guard message.sequence > 0,
            message.issuedAtUnixMilliseconds > 0,
            (50 ... 1_500).contains(message.leaseMilliseconds),
            message.issuedAtUnixMilliseconds <= nowUnixMilliseconds + 5_000,
            message.deadManIsHeld
        else { throw RobotArmWireError.invalid("Invalid target sequence, timestamp, or lease.") }
        let expiry = message.issuedAtUnixMilliseconds.addingReportingOverflow(
            Int64(message.leaseMilliseconds)
        )
        guard !expiry.overflow, nowUnixMilliseconds <= expiry.partialValue else {
            throw RobotArmWireError.invalid("The target lease expired.")
        }
    }

    private static func validateAuthorityWire(
        _ message: RobotArmAuthorityIntentWireMessage,
        nowUnixMilliseconds: Int64
    ) throws {
        let validLease = switch message.operation {
        case .acquire: (60_000 ... 600_000).contains(message.leaseMilliseconds)
        case .release: message.leaseMilliseconds == 1_000
        }
        guard message.sequence > 0,
            message.issuedAtUnixMilliseconds > 0,
            validLease,
            message.issuedAtUnixMilliseconds <= nowUnixMilliseconds + 5_000
        else { throw RobotArmWireError.invalid("Invalid authority sequence, timestamp, or lease.") }
    }

    private static func validateHoldWire(
        _ message: RobotArmHoldIntentWireMessage,
        nowUnixMilliseconds: Int64
    ) throws {
        guard message.sequence > 0,
            message.issuedAtUnixMilliseconds > 0,
            (50 ... 1_500).contains(message.leaseMilliseconds),
            message.issuedAtUnixMilliseconds <= nowUnixMilliseconds + 5_000,
            !message.reason.isEmpty,
            message.reason.count <= 128
        else { throw RobotArmWireError.invalid("Invalid hold sequence, timestamp, lease, or reason.") }
        let expiry = message.issuedAtUnixMilliseconds.addingReportingOverflow(
            Int64(message.leaseMilliseconds)
        )
        guard !expiry.overflow, nowUnixMilliseconds <= expiry.partialValue else {
            throw RobotArmWireError.invalid("The hold lease expired.")
        }
    }

    private static func encodeBounded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(value) }
        catch { throw RobotArmWireError.malformed }
        guard data.count <= maximumMessageBytes else { throw RobotArmWireError.oversized }
        return data
    }

    private static func currentUnixMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
}

public struct RobotArmControlSnapshot: Equatable, Sendable {
    public var authorityState: RobotArmAuthorityState?
    public var localControlIsArmed: Bool
    public var pendingAuthorityRequestID: UUID?
    public var activeTargetMessageID: UUID?
    public var activeTargetSentAtUptime: TimeInterval?
    public var pendingHoldMessageID: UUID?
    public var lastDisposition: RobotArmTargetDisposition?

    public init(
        authorityState: RobotArmAuthorityState? = nil,
        localControlIsArmed: Bool = false,
        pendingAuthorityRequestID: UUID? = nil,
        activeTargetMessageID: UUID? = nil,
        activeTargetSentAtUptime: TimeInterval? = nil,
        pendingHoldMessageID: UUID? = nil,
        lastDisposition: RobotArmTargetDisposition? = nil
    ) {
        self.authorityState = authorityState
        self.localControlIsArmed = localControlIsArmed
        self.pendingAuthorityRequestID = pendingAuthorityRequestID
        self.activeTargetMessageID = activeTargetMessageID
        self.activeTargetSentAtUptime = activeTargetSentAtUptime
        self.pendingHoldMessageID = pendingHoldMessageID
        self.lastDisposition = lastDisposition
    }

    public var authorityID: UUID? {
        guard authorityState?.state == .granted,
            authorityState?.expiresAt.timeIntervalSinceNow ?? 0 > 0
        else { return nil }
        return authorityState?.authorityID
    }
}

public struct RobotArmTelemetrySnapshot: Equatable, Sendable {
    public var left: RobotArmMeasuredState?
    public var right: RobotArmMeasuredState?
    public var leftReceivedAtUptime: TimeInterval?
    public var rightReceivedAtUptime: TimeInterval?
    public var leftControl: RobotArmControlSnapshot
    public var rightControl: RobotArmControlSnapshot
    public var lastTargetDisposition: RobotArmTargetDisposition?

    public init(
        left: RobotArmMeasuredState? = nil,
        right: RobotArmMeasuredState? = nil,
        leftReceivedAtUptime: TimeInterval? = nil,
        rightReceivedAtUptime: TimeInterval? = nil,
        leftControl: RobotArmControlSnapshot = RobotArmControlSnapshot(),
        rightControl: RobotArmControlSnapshot = RobotArmControlSnapshot(),
        lastTargetDisposition: RobotArmTargetDisposition? = nil
    ) {
        self.left = left
        self.right = right
        self.leftReceivedAtUptime = leftReceivedAtUptime
        self.rightReceivedAtUptime = rightReceivedAtUptime
        self.leftControl = leftControl
        self.rightControl = rightControl
        self.lastTargetDisposition = lastTargetDisposition
    }

    public mutating func apply(
        _ state: RobotArmMeasuredState,
        receivedAtUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        switch state.arm {
        case .left:
            guard left.map({ state.sequence > $0.sequence }) ?? true else { return }
            left = state
            leftReceivedAtUptime = receivedAtUptime
        case .right:
            guard right.map({ state.sequence > $0.sequence }) ?? true else { return }
            right = state
            rightReceivedAtUptime = receivedAtUptime
        }
    }

    public func measuredState(for arm: RobotArmSide) -> RobotArmMeasuredState? {
        arm == .left ? left : right
    }

    public func controlState(for arm: RobotArmSide) -> RobotArmControlSnapshot {
        arm == .left ? leftControl : rightControl
    }

    public mutating func updateControlState(
        for arm: RobotArmSide,
        _ update: (inout RobotArmControlSnapshot) -> Void
    ) {
        if arm == .left { update(&leftControl) } else { update(&rightControl) }
    }

    public func effectiveSampleAgeMilliseconds(
        for arm: RobotArmSide,
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Double? {
        guard let state = measuredState(for: arm) else { return nil }
        let receivedAt = arm == .left ? leftReceivedAtUptime : rightReceivedAtUptime
        guard let receivedAt else { return nil }
        return state.sampleAgeMilliseconds + max(0, nowUptime - receivedAt) * 1_000
    }
}
