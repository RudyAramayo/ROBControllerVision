import Foundation

public enum RobotGripperAction: String, Codable, CaseIterable, Hashable, Sendable {
    case release
    case hold
}

public enum RobotGripperCalibrationState: String, Codable, CaseIterable, Hashable, Sendable {
    case required
    case commandAcceptedUnverified = "command_accepted_unverified"
}

public struct RobotGripperCommandIntent: Codable, Hashable, Sendable {
    /// The vendor API accepts a wider 1...300 range, but the shipped Amber
    /// dashboard exercises 2...20. Vision deliberately stays in that smaller
    /// operator range until physical force calibration data exists.
    public static let forceRange = 2 ... 20

    public let arm: RobotArmSide
    public let action: RobotGripperAction
    public let force: Int

    public init?(arm: RobotArmSide, action: RobotGripperAction, force: Int) {
        guard Self.forceRange.contains(force) else { return nil }
        self.arm = arm
        self.action = action
        self.force = force
    }

    private enum CodingKeys: String, CodingKey { case arm, action, force }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self.init(
            arm: try container.decode(RobotArmSide.self, forKey: .arm),
            action: try container.decode(RobotGripperAction.self, forKey: .action),
            force: try container.decode(Int.self, forKey: .force)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .force,
                in: container,
                debugDescription: "Vision gripper force must be 2 through 20 vendor units."
            )
        }
        self = value
    }
}

public struct RobotGripperCommand: Codable, Hashable, Sendable {
    public let intent: RobotGripperCommandIntent
    public let deadManIsHeld: Bool

    public init(intent: RobotGripperCommandIntent, deadManIsHeld: Bool) {
        self.intent = intent
        self.deadManIsHeld = deadManIsHeld
    }
}

public struct RobotGripperState: Codable, Hashable, Sendable {
    public let messageID: UUID
    public let arm: RobotArmSide
    public let sequence: UInt64
    public let sampledAtUnixMilliseconds: Int64
    public let calibrationState: RobotGripperCalibrationState
    public let calibrationVerified: Bool
    public let feedbackAvailable: Bool
    public let commandInFlight: Bool
    public let lastAction: RobotGripperAction?
    public let lastForce: Int?
    public let detail: String

    public init?(
        messageID: UUID = UUID(),
        arm: RobotArmSide,
        sequence: UInt64,
        sampledAtUnixMilliseconds: Int64,
        calibrationState: RobotGripperCalibrationState,
        calibrationVerified: Bool,
        feedbackAvailable: Bool,
        commandInFlight: Bool,
        lastAction: RobotGripperAction?,
        lastForce: Int?,
        detail: String
    ) {
        guard sequence > 0, sampledAtUnixMilliseconds > 0,
            !calibrationVerified, !feedbackAvailable,
            lastForce.map({ (1 ... 300).contains($0) }) ?? true,
            !detail.isEmpty, detail.count <= 256
        else { return nil }
        self.messageID = messageID
        self.arm = arm
        self.sequence = sequence
        self.sampledAtUnixMilliseconds = sampledAtUnixMilliseconds
        self.calibrationState = calibrationState
        self.calibrationVerified = calibrationVerified
        self.feedbackAvailable = feedbackAvailable
        self.commandInFlight = commandInFlight
        self.lastAction = lastAction
        self.lastForce = lastForce
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case arm, sequence
        case sampledAtUnixMilliseconds = "sampled_at_unix_ms"
        case calibrationState = "calibration_state"
        case calibrationVerified = "calibration_verified"
        case feedbackAvailable = "feedback_available"
        case commandInFlight = "command_in_flight"
        case lastAction = "last_action"
        case lastForce = "last_force"
        case detail
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self.init(
            messageID: try container.decode(UUID.self, forKey: .messageID),
            arm: try container.decode(RobotArmSide.self, forKey: .arm),
            sequence: try container.decode(UInt64.self, forKey: .sequence),
            sampledAtUnixMilliseconds: try container.decode(
                Int64.self, forKey: .sampledAtUnixMilliseconds
            ),
            calibrationState: try container.decode(
                RobotGripperCalibrationState.self, forKey: .calibrationState
            ),
            calibrationVerified: try container.decode(Bool.self, forKey: .calibrationVerified),
            feedbackAvailable: try container.decode(Bool.self, forKey: .feedbackAvailable),
            commandInFlight: try container.decode(Bool.self, forKey: .commandInFlight),
            lastAction: try container.decodeIfPresent(RobotGripperAction.self, forKey: .lastAction),
            lastForce: try container.decodeIfPresent(Int.self, forKey: .lastForce),
            detail: try container.decode(String.self, forKey: .detail)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .calibrationState,
                in: container,
                debugDescription: "Invalid or falsely measured gripper state."
            )
        }
        self = value
    }
}

public enum RobotGripperDispositionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case dispatchAcknowledgedUnverified = "dispatch_acknowledged_unverified"
    case rejectedAuthorityDisabled = "rejected_authority_disabled"
    case rejectedCalibrationRequired = "rejected_calibration_required"
    case rejectedDeadMan = "rejected_dead_man"
    case rejectedIdentityMismatch = "rejected_identity_mismatch"
    case rejectedSessionInactive = "rejected_session_inactive"
    case rejectedExpired = "rejected_expired"
    case rejectedStaleSequence = "rejected_stale_sequence"
    case rejectedBusy = "rejected_busy"
    case rejectedInvalid = "rejected_invalid"
    case gatewayRejected = "gateway_rejected"
}

public struct RobotGripperCommandDisposition: Codable, Hashable, Sendable {
    public let messageID: UUID
    public let requestMessageID: UUID
    public let recipientID: UUID
    public let sessionID: UUID
    public let arm: RobotArmSide
    public let receivedAtUnixMilliseconds: Int64
    public let disposition: RobotGripperDispositionKind
    public let terminal: Bool
    public let detail: String
    public let calibrationState: RobotGripperCalibrationState
    public let calibrationVerified: Bool
    public let feedbackAvailable: Bool
    public let action: RobotGripperAction?
    public let force: Int?

    public init?(
        messageID: UUID = UUID(),
        requestMessageID: UUID,
        recipientID: UUID,
        sessionID: UUID,
        arm: RobotArmSide,
        receivedAtUnixMilliseconds: Int64,
        disposition: RobotGripperDispositionKind,
        terminal: Bool,
        detail: String,
        calibrationState: RobotGripperCalibrationState,
        calibrationVerified: Bool,
        feedbackAvailable: Bool,
        action: RobotGripperAction?,
        force: Int?
    ) {
        guard receivedAtUnixMilliseconds > 0, terminal,
            !calibrationVerified, !feedbackAvailable,
            !detail.isEmpty, detail.count <= 256,
            force.map({ (1 ... 300).contains($0) }) ?? true
        else { return nil }
        self.messageID = messageID
        self.requestMessageID = requestMessageID
        self.recipientID = recipientID
        self.sessionID = sessionID
        self.arm = arm
        self.receivedAtUnixMilliseconds = receivedAtUnixMilliseconds
        self.disposition = disposition
        self.terminal = terminal
        self.detail = detail
        self.calibrationState = calibrationState
        self.calibrationVerified = calibrationVerified
        self.feedbackAvailable = feedbackAvailable
        self.action = action
        self.force = force
    }

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case requestMessageID = "request_message_id"
        case recipientID = "recipient_id"
        case sessionID = "session_id"
        case arm
        case receivedAtUnixMilliseconds = "received_at_unix_ms"
        case disposition, terminal, detail
        case calibrationState = "calibration_state"
        case calibrationVerified = "calibration_verified"
        case feedbackAvailable = "feedback_available"
        case action, force
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self.init(
            messageID: try container.decode(UUID.self, forKey: .messageID),
            requestMessageID: try container.decode(UUID.self, forKey: .requestMessageID),
            recipientID: try container.decode(UUID.self, forKey: .recipientID),
            sessionID: try container.decode(UUID.self, forKey: .sessionID),
            arm: try container.decode(RobotArmSide.self, forKey: .arm),
            receivedAtUnixMilliseconds: try container.decode(
                Int64.self, forKey: .receivedAtUnixMilliseconds
            ),
            disposition: try container.decode(
                RobotGripperDispositionKind.self, forKey: .disposition
            ),
            terminal: try container.decode(Bool.self, forKey: .terminal),
            detail: try container.decode(String.self, forKey: .detail),
            calibrationState: try container.decode(
                RobotGripperCalibrationState.self, forKey: .calibrationState
            ),
            calibrationVerified: try container.decode(Bool.self, forKey: .calibrationVerified),
            feedbackAvailable: try container.decode(Bool.self, forKey: .feedbackAvailable),
            action: try container.decodeIfPresent(RobotGripperAction.self, forKey: .action),
            force: try container.decodeIfPresent(Int.self, forKey: .force)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .terminal,
                in: container,
                debugDescription: "Invalid gripper disposition."
            )
        }
        self = value
    }
}

public enum RobotGripperWireDecodedMessage: Hashable, Sendable {
    case state(RobotGripperState)
    case commandIntent(RobotGripperCommandWireMessage)
    case commandDisposition(RobotGripperCommandDisposition)
}

public struct RobotGripperCommandWireMessage: Codable, Hashable, Sendable {
    public let messageID: UUID
    public let senderID: UUID
    public let sessionID: UUID
    public let sequence: UInt64
    public let issuedAtUnixMilliseconds: Int64
    public let leaseMilliseconds: UInt32
    public let arm: RobotArmSide
    public let action: RobotGripperAction
    public let force: Int
    public let deadManHeld: Bool

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case senderID = "sender_id"
        case sessionID = "session_id"
        case sequence
        case issuedAtUnixMilliseconds = "issued_at_unix_ms"
        case leaseMilliseconds = "lease_ms"
        case arm, action, force
        case deadManHeld = "dead_man_held"
    }
}

public enum RobotGripperWireError: Error, Equatable, Sendable {
    case oversized
    case malformed
    case unknownType
    case unexpectedFields
    case invalid(String)
}

public enum RobotGripperWireCodec {
    public static let protocolName = "rob-gripper-control/1"
    public static let schemaVersion = 1
    public static let maximumMessageBytes = 4 * 1_024

    private struct WireEnvelope<T: Codable>: Codable {
        let protocolName: String
        let schemaVersion: Int
        let type: String
        let payload: T

        init(type: String, payload: T) {
            protocolName = RobotGripperWireCodec.protocolName
            schemaVersion = RobotGripperWireCodec.schemaVersion
            self.type = type
            self.payload = payload
        }

        private enum CodingKeys: String, CodingKey {
            case protocolName = "protocol"
            case schemaVersion = "schema_version"
            case type
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

    private static let stateKeys: Set<String> = [
        "protocol", "schema_version", "type", "message_id", "arm", "sequence",
        "sampled_at_unix_ms", "calibration_state", "calibration_verified",
        "feedback_available", "command_in_flight", "last_action", "last_force", "detail",
    ]
    private static let intentKeys: Set<String> = [
        "protocol", "schema_version", "type", "message_id", "sender_id", "session_id",
        "sequence", "issued_at_unix_ms", "lease_ms", "arm", "action", "force",
        "dead_man_held",
    ]
    private static let dispositionKeys: Set<String> = [
        "protocol", "schema_version", "type", "message_id", "request_message_id",
        "recipient_id", "session_id", "arm", "received_at_unix_ms", "disposition",
        "terminal", "detail", "calibration_state", "calibration_verified",
        "feedback_available", "action", "force",
    ]

    public static func decode(
        _ data: Data,
        nowUnixMilliseconds: Int64? = nil
    ) throws -> RobotGripperWireDecodedMessage? {
        guard !data.isEmpty else { return nil }
        guard data.count <= maximumMessageBytes else { throw RobotGripperWireError.oversized }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        guard dictionary["protocol"] as? String == protocolName else { return nil }
        guard dictionary["schema_version"] as? Int == schemaVersion,
              let type = dictionary["type"] as? String else {
            throw RobotGripperWireError.malformed
        }
        let decoder = JSONDecoder()
        do {
            switch type {
            case "state":
                try requireKeys(dictionary, allowed: stateKeys, required: stateKeys.subtracting(["last_action", "last_force"]))
                return .state(try decoder.decode(WireEnvelope<RobotGripperState>.self, from: data).payload)
            case "command_intent":
                try requireKeys(dictionary, allowed: intentKeys, required: intentKeys)
                let message = try decoder.decode(
                    WireEnvelope<RobotGripperCommandWireMessage>.self, from: data
                ).payload
                try validateIntent(
                    message,
                    nowUnixMilliseconds: nowUnixMilliseconds ?? currentUnixMilliseconds()
                )
                return .commandIntent(message)
            case "command_disposition":
                try requireKeys(dictionary, allowed: dispositionKeys, required: dispositionKeys.subtracting(["action", "force"]))
                return .commandDisposition(
                    try decoder.decode(
                        WireEnvelope<RobotGripperCommandDisposition>.self, from: data
                    ).payload
                )
            default:
                throw RobotGripperWireError.unknownType
            }
        } catch let error as RobotGripperWireError {
            throw error
        } catch {
            throw RobotGripperWireError.malformed
        }
    }

    public static func encodeCommandIntent(
        _ intent: RobotGripperCommandIntent,
        messageID: UUID,
        senderID: UUID,
        sessionID: UUID,
        sequence: UInt64,
        issuedAtUnixMilliseconds: Int64,
        leaseMilliseconds: UInt32,
        deadManHeld: Bool,
        nowUnixMilliseconds: Int64? = nil
    ) throws -> Data {
        let message = RobotGripperCommandWireMessage(
            messageID: messageID,
            senderID: senderID,
            sessionID: sessionID,
            sequence: sequence,
            issuedAtUnixMilliseconds: issuedAtUnixMilliseconds,
            leaseMilliseconds: leaseMilliseconds,
            arm: intent.arm,
            action: intent.action,
            force: intent.force,
            deadManHeld: deadManHeld
        )
        try validateIntent(
            message,
            nowUnixMilliseconds: nowUnixMilliseconds ?? currentUnixMilliseconds()
        )
        return try encodeBounded(WireEnvelope(type: "command_intent", payload: message))
    }

    public static func encodeState(_ state: RobotGripperState) throws -> Data {
        try encodeBounded(WireEnvelope(type: "state", payload: state))
    }

    public static func encodeCommandDisposition(
        _ disposition: RobotGripperCommandDisposition
    ) throws -> Data {
        try encodeBounded(WireEnvelope(type: "command_disposition", payload: disposition))
    }

    private static func validateIntent(
        _ message: RobotGripperCommandWireMessage,
        nowUnixMilliseconds: Int64
    ) throws {
        guard message.sequence > 0, message.issuedAtUnixMilliseconds > 0,
              (100 ... 1_000).contains(message.leaseMilliseconds),
              RobotGripperCommandIntent.forceRange.contains(message.force),
              message.deadManHeld,
              message.issuedAtUnixMilliseconds <= nowUnixMilliseconds + 5_000 else {
            throw RobotGripperWireError.invalid("Invalid gripper command bounds or dead-man state.")
        }
        let expiry = message.issuedAtUnixMilliseconds.addingReportingOverflow(
            Int64(message.leaseMilliseconds)
        )
        guard !expiry.overflow, nowUnixMilliseconds <= expiry.partialValue else {
            throw RobotGripperWireError.invalid("The gripper command lease expired.")
        }
    }

    private static func requireKeys(
        _ dictionary: [String: Any], allowed: Set<String>, required: Set<String>
    ) throws {
        let keys = Set(dictionary.keys)
        guard keys.isSubset(of: allowed), required.isSubset(of: keys) else {
            throw RobotGripperWireError.unexpectedFields
        }
    }

    private static func encodeBounded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(value) }
        catch { throw RobotGripperWireError.malformed }
        guard data.count <= maximumMessageBytes else { throw RobotGripperWireError.oversized }
        return data
    }

    private static func currentUnixMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
}

public struct RobotGripperControlSnapshot: Equatable, Sendable {
    public var pendingCommandMessageID: UUID?
    public var lastTimedOutCommandMessageID: UUID?
    public var lastDisposition: RobotGripperCommandDisposition?

    public init(
        pendingCommandMessageID: UUID? = nil,
        lastTimedOutCommandMessageID: UUID? = nil,
        lastDisposition: RobotGripperCommandDisposition? = nil
    ) {
        self.pendingCommandMessageID = pendingCommandMessageID
        self.lastTimedOutCommandMessageID = lastTimedOutCommandMessageID
        self.lastDisposition = lastDisposition
    }
}

public struct RobotGripperTelemetrySnapshot: Equatable, Sendable {
    public var left: RobotGripperState?
    public var right: RobotGripperState?
    public var leftControl: RobotGripperControlSnapshot
    public var rightControl: RobotGripperControlSnapshot

    public init(
        left: RobotGripperState? = nil,
        right: RobotGripperState? = nil,
        leftControl: RobotGripperControlSnapshot = RobotGripperControlSnapshot(),
        rightControl: RobotGripperControlSnapshot = RobotGripperControlSnapshot()
    ) {
        self.left = left
        self.right = right
        self.leftControl = leftControl
        self.rightControl = rightControl
    }

    public mutating func apply(_ state: RobotGripperState) {
        switch state.arm {
        case .left:
            guard left.map({ state.sequence > $0.sequence }) ?? true else { return }
            left = state
        case .right:
            guard right.map({ state.sequence > $0.sequence }) ?? true else { return }
            right = state
        }
    }

    public func state(for arm: RobotArmSide) -> RobotGripperState? {
        arm == .left ? left : right
    }

    public func control(for arm: RobotArmSide) -> RobotGripperControlSnapshot {
        arm == .left ? leftControl : rightControl
    }

    public mutating func updateControl(
        for arm: RobotArmSide,
        _ update: (inout RobotGripperControlSnapshot) -> Void
    ) {
        if arm == .left { update(&leftControl) } else { update(&rightControl) }
    }
}
