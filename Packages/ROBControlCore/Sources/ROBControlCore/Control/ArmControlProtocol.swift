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

    public init?(
        arm: RobotArmSide,
        source: RobotArmTargetSource,
        positionsRadians: [Double],
        durationSeconds: Double
    ) {
        guard positionsRadians.count == Self.jointBoundsRadians.count,
            zip(positionsRadians, Self.jointBoundsRadians).allSatisfy({ position, bounds in
                position.isFinite && bounds.contains(position)
            }),
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

    public init?(
        messageID: UUID = UUID(),
        arm: RobotArmSide,
        sequence: UInt64,
        sampledAtUnixMilliseconds: Int64,
        sampleAgeMilliseconds: Double,
        positionsRadians: [Double],
        velocitiesRadiansPerSecond: [Double],
        currents: [Double],
        statuses: [Double]
    ) {
        guard sequence > 0,
            sampledAtUnixMilliseconds > 0,
            sampleAgeMilliseconds.isFinite,
            (0 ... 60_000).contains(sampleAgeMilliseconds),
            Self.validVector(positionsRadians, absoluteLimit: 4 * .pi),
            Self.validVector(velocitiesRadiansPerSecond, absoluteLimit: 100),
            Self.validVector(currents, absoluteLimit: 1_000),
            Self.validVector(statuses, absoluteLimit: 1_000_000_000)
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
        case currents, statuses
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
            statuses: try container.decode([Double].self, forKey: .statuses)
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
    case acceptedPreviewOnly = "accepted_preview_only"
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
}

public struct RobotArmTargetDisposition: Codable, Hashable, Sendable {
    public let messageID: UUID
    public let targetMessageID: UUID
    public let recipientID: UUID
    public let receivedAtUnixMilliseconds: Int64
    public let disposition: RobotArmTargetDispositionKind
    public let executionEligible: Bool
    public let detail: String

    public init?(
        messageID: UUID = UUID(),
        targetMessageID: UUID,
        recipientID: UUID,
        receivedAtUnixMilliseconds: Int64,
        disposition: RobotArmTargetDispositionKind,
        executionEligible: Bool,
        detail: String
    ) {
        guard receivedAtUnixMilliseconds > 0,
            executionEligible == false,
            !detail.isEmpty,
            detail.count <= 256
        else { return nil }
        self.messageID = messageID
        self.targetMessageID = targetMessageID
        self.recipientID = recipientID
        self.receivedAtUnixMilliseconds = receivedAtUnixMilliseconds
        self.disposition = disposition
        self.executionEligible = false
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case targetMessageID = "target_message_id"
        case recipientID = "recipient_id"
        case receivedAtUnixMilliseconds = "received_at_unix_ms"
        case disposition
        case executionEligible = "execution_eligible"
        case detail
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self.init(
            messageID: try container.decode(UUID.self, forKey: .messageID),
            targetMessageID: try container.decode(UUID.self, forKey: .targetMessageID),
            recipientID: try container.decode(UUID.self, forKey: .recipientID),
            receivedAtUnixMilliseconds: try container.decode(
                Int64.self,
                forKey: .receivedAtUnixMilliseconds
            ),
            disposition: try container.decode(
                RobotArmTargetDispositionKind.self,
                forKey: .disposition
            ),
            executionEligible: try container.decode(Bool.self, forKey: .executionEligible),
            detail: try container.decode(String.self, forKey: .detail)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .executionEligible,
                in: container,
                debugDescription: "Arm protocol v1 dispositions must remain preview-only."
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
    public let target: RobotArmTargetIntent

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case senderID = "sender_id"
        case sessionID = "session_id"
        case sequence
        case issuedAtUnixMilliseconds = "issued_at_unix_ms"
        case leaseMilliseconds = "lease_ms"
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
        target: RobotArmTargetIntent
    ) {
        self.messageID = messageID
        self.senderID = senderID
        self.sessionID = sessionID
        self.sequence = sequence
        self.issuedAtUnixMilliseconds = issuedAtUnixMilliseconds
        self.leaseMilliseconds = leaseMilliseconds
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
        try container.encode(target.arm, forKey: .arm)
        try container.encode(target.source, forKey: .source)
        try container.encode(target.positionsRadians, forKey: .positionsRadians)
        try container.encode(target.durationSeconds, forKey: .durationSeconds)
    }
}

public enum RobotArmWireDecodedMessage: Hashable, Sendable {
    case measuredState(RobotArmMeasuredState)
    case targetIntent(RobotArmTargetIntentWireMessage)
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
    public static let protocolName = "rob-arm-control/1"
    public static let schemaVersion = 1
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
        "currents", "statuses",
    ]
    private static let targetKeys: Set<String> = [
        "protocol", "schema_version", "type", "message_id", "sender_id", "session_id",
        "sequence", "issued_at_unix_ms", "lease_ms", "arm", "source", "positions_rad",
        "duration_s",
    ]
    private static let dispositionKeys: Set<String> = [
        "protocol", "schema_version", "type", "message_id", "target_message_id",
        "recipient_id", "received_at_unix_ms", "disposition", "execution_eligible", "detail",
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
                guard Set(dictionary.keys).isSubset(of: measuredKeys) else {
                    throw RobotArmWireError.unexpectedFields
                }
                let envelope = try decoder.decode(
                    WireEnvelope<RobotArmMeasuredState>.self,
                    from: data
                )
                return .measuredState(envelope.payload)
            case "target_intent":
                guard Set(dictionary.keys).isSubset(of: targetKeys) else {
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
            case "target_disposition":
                guard Set(dictionary.keys).isSubset(of: dispositionKeys) else {
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
        nowUnixMilliseconds: Int64? = nil
    ) throws -> Data {
        let message = RobotArmTargetIntentWireMessage(
            messageID: messageID,
            senderID: senderID,
            sessionID: sessionID,
            sequence: sequence,
            issuedAtUnixMilliseconds: issuedAtUnixMilliseconds,
            leaseMilliseconds: leaseMilliseconds,
            target: target
        )
        try validateTargetWire(
            message,
            nowUnixMilliseconds: nowUnixMilliseconds ?? currentUnixMilliseconds()
        )
        return try encodeBounded(WireEnvelope(type: "target_intent", payload: message))
    }

    public static func encodeMeasuredState(_ state: RobotArmMeasuredState) throws -> Data {
        try encodeBounded(WireEnvelope(type: "measured_state", payload: state))
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
            (50 ... 1_000).contains(message.leaseMilliseconds),
            message.issuedAtUnixMilliseconds <= nowUnixMilliseconds + 5_000
        else { throw RobotArmWireError.invalid("Invalid target sequence, timestamp, or lease.") }
        let expiry = message.issuedAtUnixMilliseconds.addingReportingOverflow(
            Int64(message.leaseMilliseconds)
        )
        guard !expiry.overflow, nowUnixMilliseconds <= expiry.partialValue else {
            throw RobotArmWireError.invalid("The target lease expired.")
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

public struct RobotArmTelemetrySnapshot: Equatable, Sendable {
    public var left: RobotArmMeasuredState?
    public var right: RobotArmMeasuredState?
    public var lastTargetDisposition: RobotArmTargetDisposition?

    public init(
        left: RobotArmMeasuredState? = nil,
        right: RobotArmMeasuredState? = nil,
        lastTargetDisposition: RobotArmTargetDisposition? = nil
    ) {
        self.left = left
        self.right = right
        self.lastTargetDisposition = lastTargetDisposition
    }

    public mutating func apply(_ state: RobotArmMeasuredState) {
        switch state.arm {
        case .left: left = state
        case .right: right = state
        }
    }
}
