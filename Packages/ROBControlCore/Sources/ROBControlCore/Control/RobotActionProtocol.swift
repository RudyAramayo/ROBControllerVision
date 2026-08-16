import Foundation

public enum RobotActionName: String, Codable, CaseIterable, Hashable, Sendable {
    case lookAt = "look_at"
    case playGesture = "play_gesture"
    case requestPick = "request_pick"
    case navigateRelative = "navigate_relative"
    case stopMotion = "stop_motion"
}

public enum RobotActionMessageKind: String, Codable, Hashable, Sendable {
    case controllerHello = "controller_hello"
    case actionRequest = "action_request"
    case actionStatus = "action_status"
    case actionCancel = "action_cancel"
}

public enum RobotActionState: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case pending
    case accepted
    case executing
    case completed
    case rejected
    case cancelled
    case failed
    case expired

    public var isTerminal: Bool {
        switch self {
        case .completed, .rejected, .cancelled, .failed, .expired: true
        case .none, .pending, .accepted, .executing: false
        }
    }
}

public indirect enum RobotActionJSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([RobotActionJSONValue])
    case object([String: RobotActionJSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self), value.isFinite {
            self = .number(value)
        } else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([RobotActionJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: RobotActionJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Robot action JSON contains an unsupported value."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(value, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Robot action numbers must be finite."
                ))
            }
            try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }
}

public struct RobotActionMessage: Codable, Hashable, Sendable, Identifiable {
    public static let schema = "com.orbitusrobotics.robot-action"
    public static let version = 1
    public static let envelopeMarker = "ROBRobotActionProtocol.v1"
    public static let maximumPayloadBytes = 65_536

    public let schemaIdentifier: String
    public let version: Int
    public let messageID: String
    public let kind: RobotActionMessageKind
    public let callID: String?
    public let senderID: String
    public let recipientID: String?
    public let sentAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64?
    public let action: RobotActionName?
    public let arguments: [String: RobotActionJSONValue]
    public let state: RobotActionState
    public let detail: String?
    public let result: [String: RobotActionJSONValue]
    public let acceptsActions: Bool?
    public let capabilities: [RobotActionName]

    public var id: String { messageID }
    public var isExpired: Bool {
        guard let expiresAtMilliseconds else { return false }
        return Self.nowMilliseconds >= expiresAtMilliseconds
    }

    public init(
        messageID: String = UUID().uuidString,
        kind: RobotActionMessageKind,
        callID: String? = nil,
        senderID: String,
        recipientID: String? = nil,
        sentAtMilliseconds: Int64 = RobotActionMessage.nowMilliseconds,
        expiresAtMilliseconds: Int64? = nil,
        action: RobotActionName? = nil,
        arguments: [String: RobotActionJSONValue] = [:],
        state: RobotActionState = .none,
        detail: String? = nil,
        result: [String: RobotActionJSONValue] = [:],
        acceptsActions: Bool? = nil,
        capabilities: [RobotActionName] = []
    ) throws {
        schemaIdentifier = Self.schema
        version = Self.version
        self.messageID = messageID
        self.kind = kind
        self.callID = callID
        self.senderID = senderID
        self.recipientID = recipientID
        self.sentAtMilliseconds = sentAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.action = action
        self.arguments = arguments
        self.state = state
        self.detail = detail
        self.result = result
        self.acceptsActions = acceptsActions
        self.capabilities = capabilities
        if let error = validationError { throw RobotActionProtocolError.invalid(error) }
    }

    public static func controllerHello(
        senderID: String,
        acceptsActions: Bool,
        capabilities: [RobotActionName] = RobotActionName.allCases
    ) throws -> Self {
        try Self(
            kind: .controllerHello,
            senderID: senderID,
            acceptsActions: acceptsActions,
            capabilities: capabilities
        )
    }

    public static func status(
        for request: RobotActionMessage,
        state: RobotActionState,
        detail: String,
        result: [String: RobotActionJSONValue] = [:],
        senderID: String
    ) throws -> Self {
        guard let callID = request.callID else {
            throw RobotActionProtocolError.invalid("Request has no call ID.")
        }
        return try Self(
            kind: .actionStatus,
            callID: callID,
            senderID: senderID,
            recipientID: request.senderID,
            state: state,
            detail: detail,
            result: result
        )
    }

    public var validationError: String? {
        guard schemaIdentifier == Self.schema, version == Self.version else {
            return "Unsupported robot-action schema."
        }
        guard !messageID.isEmpty, messageID.count <= 128,
              !senderID.isEmpty, senderID.count <= 128,
              sentAtMilliseconds > 0 else { return "Invalid message identity or timestamp." }
        if let recipientID, recipientID.isEmpty || recipientID.count > 128 {
            return "Invalid recipient ID."
        }
        if let detail, detail.count > 2_048 { return "Detail exceeds 2048 characters." }
        switch kind {
        case .controllerHello:
            guard acceptsActions != nil, action == nil, callID == nil else {
                return "Invalid controller hello."
            }
        case .actionRequest:
            guard let callID, !callID.isEmpty, callID.count <= 128,
                  let action,
                  state == .pending,
                  let expiresAtMilliseconds,
                  expiresAtMilliseconds > sentAtMilliseconds,
                  expiresAtMilliseconds - sentAtMilliseconds <= 120_000 else {
                return "Invalid action request."
            }
            if let error = Self.validate(arguments: arguments, action: action) { return error }
        case .actionStatus:
            guard let callID, !callID.isEmpty, callID.count <= 128,
                  state != .none else { return "Invalid action status." }
        case .actionCancel:
            guard let callID, !callID.isEmpty, callID.count <= 128 else {
                return "Invalid action cancellation."
            }
        }
        return nil
    }

    private static func validate(
        arguments: [String: RobotActionJSONValue],
        action: RobotActionName
    ) -> String? {
        switch action {
        case .lookAt, .requestPick:
            guard Set(arguments.keys) == ["target_id"],
                  let value = arguments["target_id"]?.stringValue,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= 256 else { return "Action requires a bounded target_id." }
        case .playGesture:
            guard Set(arguments.keys) == ["gesture"],
                  let value = arguments["gesture"]?.stringValue,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= 128 else { return "play_gesture requires a gesture name." }
        case .navigateRelative:
            guard Set(arguments.keys) == ["distance_m", "yaw_rad", "speed_scale"],
                  let distance = arguments["distance_m"]?.numberValue,
                  (-1 ... 1).contains(distance),
                  let yaw = arguments["yaw_rad"]?.numberValue,
                  (-Double.pi ... Double.pi).contains(yaw),
                  let speed = arguments["speed_scale"]?.numberValue,
                  (0 ... 0.35).contains(speed) else {
                return "navigate_relative arguments exceed their bounds."
            }
        case .stopMotion:
            guard arguments.isEmpty else { return "stop_motion takes no arguments." }
        }
        return nil
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaIdentifier = "schema"
        case version
        case messageID = "message_id"
        case kind
        case callID = "call_id"
        case senderID = "sender_id"
        case recipientID = "recipient_id"
        case sentAtMilliseconds = "sent_at_ms"
        case expiresAtMilliseconds = "expires_at_ms"
        case action, arguments, state, detail, result
        case acceptsActions = "accepts_actions"
        case capabilities
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaIdentifier = try container.decode(String.self, forKey: .schemaIdentifier)
        version = try container.decode(Int.self, forKey: .version)
        messageID = try container.decode(String.self, forKey: .messageID)
        kind = try container.decode(RobotActionMessageKind.self, forKey: .kind)
        callID = try container.decodeIfPresent(String.self, forKey: .callID)
        senderID = try container.decode(String.self, forKey: .senderID)
        recipientID = try container.decodeIfPresent(String.self, forKey: .recipientID)
        sentAtMilliseconds = try container.decode(Int64.self, forKey: .sentAtMilliseconds)
        expiresAtMilliseconds = try container.decodeIfPresent(
            Int64.self,
            forKey: .expiresAtMilliseconds
        )
        action = try container.decodeIfPresent(RobotActionName.self, forKey: .action)
        arguments = try container.decodeIfPresent(
            [String: RobotActionJSONValue].self,
            forKey: .arguments
        ) ?? [:]
        state = try container.decodeIfPresent(RobotActionState.self, forKey: .state) ?? .none
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        result = try container.decodeIfPresent(
            [String: RobotActionJSONValue].self,
            forKey: .result
        ) ?? [:]
        acceptsActions = try container.decodeIfPresent(Bool.self, forKey: .acceptsActions)
        capabilities = try container.decodeIfPresent(
            [RobotActionName].self,
            forKey: .capabilities
        ) ?? []
        if let error = validationError {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: error
            )
        }
    }

    public static var nowMilliseconds: Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
}

public enum RobotActionProtocolError: Error, Equatable, LocalizedError, Sendable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): "Invalid robot action: \(detail)"
        }
    }
}

/// Latest-value state for the Vision operator approval console.
///
/// Approval is deliberately session-local and defaults off. An accepted
/// request remains visible until Cerebro reports a terminal outcome (or the
/// operator cancels it), so transport acceptance cannot be mistaken for
/// physical completion.
public struct RobotActionApprovalSnapshot: Equatable, Sendable {
    public var isEnabled: Bool
    public var controllerID: String?
    public var pendingRequest: RobotActionMessage?
    public var lastStatus: RobotActionMessage?

    public init(
        isEnabled: Bool = false,
        controllerID: String? = nil,
        pendingRequest: RobotActionMessage? = nil,
        lastStatus: RobotActionMessage? = nil
    ) {
        self.isEnabled = isEnabled
        self.controllerID = controllerID
        self.pendingRequest = pendingRequest
        self.lastStatus = lastStatus
    }

    public var isAwaitingOperatorDecision: Bool {
        guard let request = pendingRequest else { return false }
        guard let status = lastStatus, status.callID == request.callID else { return true }
        return status.state != .accepted && status.state != .executing
    }
}

public enum RobotActionWireCodec {
    public static func encodeJSON(_ message: RobotActionMessage) throws -> Data {
        guard message.validationError == nil else {
            throw RobotActionProtocolError.invalid(message.validationError ?? "Invalid message.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(message)
        guard data.count <= RobotActionMessage.maximumPayloadBytes else {
            throw RobotActionProtocolError.invalid("Payload exceeds 64 KiB.")
        }
        return data
    }

    public static func decodeJSON(_ data: Data) throws -> RobotActionMessage {
        guard !data.isEmpty, data.count <= RobotActionMessage.maximumPayloadBytes else {
            throw RobotActionProtocolError.invalid("Payload is empty or too large.")
        }
        return try JSONDecoder().decode(RobotActionMessage.self, from: data)
    }

    public static func archive(_ message: RobotActionMessage) throws -> Data {
        let payload = try encodeJSON(message)
        let envelope: NSDictionary = [
            "message": RobotActionMessage.envelopeMarker,
            "sender": message.senderID,
            "robot_action": payload,
        ]
        return try NSKeyedArchiver.archivedData(
            withRootObject: envelope,
            requiringSecureCoding: false
        )
    }

    public static func decodeArchive(_ data: Data) throws -> RobotActionMessage? {
        guard data.count <= RobotActionMessage.maximumPayloadBytes * 2 else { return nil }
        let allowed: [AnyClass] = [NSDictionary.self, NSString.self, NSData.self]
        guard let envelope = try? NSKeyedUnarchiver.unarchivedObject(
            ofClasses: allowed,
            from: data
        ) as? NSDictionary,
        envelope["message"] as? String == RobotActionMessage.envelopeMarker,
        let sender = envelope["sender"] as? String,
        let payload = envelope["robot_action"] as? Data else { return nil }
        let message = try decodeJSON(payload)
        guard message.senderID == sender else {
            throw RobotActionProtocolError.invalid("Envelope sender mismatch.")
        }
        return message
    }
}
