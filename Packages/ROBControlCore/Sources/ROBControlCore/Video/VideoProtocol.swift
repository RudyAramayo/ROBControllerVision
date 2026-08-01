import Foundation

public struct CameraID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct VideoSubscriptionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum VideoCodec: String, Codable, CaseIterable, Hashable, Sendable {
    case jpeg
    case h264
    case hevc
}

public enum VideoDeliveryMode: String, Codable, CaseIterable, Hashable, Sendable {
    case jpegFrames
    case reliableStream
    case quicDatagrams
}

public struct CameraDescriptor: Codable, Hashable, Identifiable, Sendable {
    public var id: CameraID
    public var name: String
    public var supportedCodecs: [VideoCodec]
    public var maximumWidth: UInt16
    public var maximumHeight: UInt16
    public var maximumFramesPerSecond: UInt16

    public init(
        id: CameraID,
        name: String,
        supportedCodecs: [VideoCodec],
        maximumWidth: UInt16,
        maximumHeight: UInt16,
        maximumFramesPerSecond: UInt16
    ) {
        self.id = id
        self.name = name
        self.supportedCodecs = supportedCodecs
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.maximumFramesPerSecond = maximumFramesPerSecond
    }
}

public struct VideoConstraints: Codable, Hashable, Sendable {
    public var maximumWidth: UInt16
    public var maximumHeight: UInt16
    public var maximumFramesPerSecond: UInt16
    public var maximumBitrate: UInt32

    public init(
        maximumWidth: UInt16 = 1_280,
        maximumHeight: UInt16 = 720,
        maximumFramesPerSecond: UInt16 = 30,
        maximumBitrate: UInt32 = 3_000_000
    ) {
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.maximumBitrate = maximumBitrate
    }

    public var isValid: Bool {
        maximumWidth > 0
            && maximumHeight > 0
            && maximumFramesPerSecond > 0
            && maximumBitrate > 0
    }
}

public struct VideoSubscriptionRequest: Codable, Hashable, Sendable {
    public let id: VideoSubscriptionID
    public let cameraID: CameraID
    public let preferredCodecs: [VideoCodec]
    public let constraints: VideoConstraints
    public let delivery: VideoDeliveryMode

    public init(
        id: VideoSubscriptionID = VideoSubscriptionID(),
        cameraID: CameraID,
        preferredCodecs: [VideoCodec] = [.h264, .jpeg],
        constraints: VideoConstraints = VideoConstraints(),
        delivery: VideoDeliveryMode = .quicDatagrams
    ) {
        self.id = id
        self.cameraID = cameraID
        self.preferredCodecs = preferredCodecs
        self.constraints = constraints
        self.delivery = delivery
    }
}

public struct VideoStreamDescriptor: Codable, Hashable, Identifiable, Sendable {
    public var id: VideoSubscriptionID
    public var cameraID: CameraID
    public var codec: VideoCodec
    public var width: UInt16
    public var height: UInt16
    public var framesPerSecond: UInt16
    public var bitrate: UInt32
    public var delivery: VideoDeliveryMode

    public init(
        id: VideoSubscriptionID,
        cameraID: CameraID,
        codec: VideoCodec,
        width: UInt16,
        height: UInt16,
        framesPerSecond: UInt16,
        bitrate: UInt32,
        delivery: VideoDeliveryMode
    ) {
        self.id = id
        self.cameraID = cameraID
        self.codec = codec
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.bitrate = bitrate
        self.delivery = delivery
    }
}

public enum VideoSubscriptionRejection: String, Codable, Error, Hashable, Sendable {
    case cameraUnavailable
    case codecUnavailable
    case invalidConstraints
    case capacityReached
    case duplicateSubscriptionID
    case deliveryUnavailable
}

public enum VideoSubscriptionError: Error, Equatable, LocalizedError, Sendable {
    case cancelled
    case timedOut
    case duplicateID(VideoSubscriptionID)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Video subscription was cancelled."
        case .timedOut: "Video subscription negotiation timed out."
        case .duplicateID(let id):
            "Video subscription ID \(id.rawValue) is already active or pending."
        }
    }
}

public enum VideoSubscriptionResponse: Hashable, Sendable {
    case accepted(VideoStreamDescriptor)
    case rejected(id: VideoSubscriptionID, reason: VideoSubscriptionRejection)
}

extension VideoSubscriptionResponse {
    public var subscriptionID: VideoSubscriptionID {
        switch self {
        case .accepted(let stream): stream.id
        case .rejected(let id, _): id
        }
    }
}

public struct VideoUnsubscribeRequest: Codable, Hashable, Sendable {
    public let id: VideoSubscriptionID

    public init(id: VideoSubscriptionID) {
        self.id = id
    }
}

public struct VideoReceiverFeedback: Codable, Hashable, Sendable {
    public let id: VideoSubscriptionID
    public var estimatedPacketLoss: Double
    public var estimatedJitterMilliseconds: Double
    public var decodedFramesPerSecond: Double
    public var desiredBitrate: UInt32?
    public var requestsKeyFrame: Bool

    public init(
        id: VideoSubscriptionID,
        estimatedPacketLoss: Double,
        estimatedJitterMilliseconds: Double,
        decodedFramesPerSecond: Double,
        desiredBitrate: UInt32? = nil,
        requestsKeyFrame: Bool = false
    ) {
        self.id = id
        self.estimatedPacketLoss =
            estimatedPacketLoss.isFinite
            ? max(0, min(1, estimatedPacketLoss))
            : 1
        self.estimatedJitterMilliseconds =
            estimatedJitterMilliseconds.isFinite
            ? max(0, estimatedJitterMilliseconds)
            : 0
        self.decodedFramesPerSecond =
            decodedFramesPerSecond.isFinite
            ? max(0, decodedFramesPerSecond)
            : 0
        self.desiredBitrate = desiredBitrate
        self.requestsKeyFrame = requestsKeyFrame
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case estimatedPacketLoss
        case estimatedJitterMilliseconds
        case decodedFramesPerSecond
        case desiredBitrate
        case requestsKeyFrame
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(VideoSubscriptionID.self, forKey: .id),
            estimatedPacketLoss: try container.decode(Double.self, forKey: .estimatedPacketLoss),
            estimatedJitterMilliseconds: try container.decode(
                Double.self,
                forKey: .estimatedJitterMilliseconds
            ),
            decodedFramesPerSecond: try container.decode(
                Double.self,
                forKey: .decodedFramesPerSecond
            ),
            desiredBitrate: try container.decodeIfPresent(UInt32.self, forKey: .desiredBitrate),
            requestsKeyFrame: try container.decode(Bool.self, forKey: .requestsKeyFrame)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(estimatedPacketLoss, forKey: .estimatedPacketLoss)
        try container.encode(estimatedJitterMilliseconds, forKey: .estimatedJitterMilliseconds)
        try container.encode(decodedFramesPerSecond, forKey: .decodedFramesPerSecond)
        try container.encodeIfPresent(desiredBitrate, forKey: .desiredBitrate)
        try container.encode(requestsKeyFrame, forKey: .requestsKeyFrame)
    }
}

public enum VideoControlMessage: Hashable, Sendable {
    case subscribe(VideoSubscriptionRequest)
    case unsubscribe(VideoUnsubscribeRequest)
    case feedback(VideoReceiverFeedback)
}

extension VideoSubscriptionResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case stream
        case id
        case reason
    }

    private enum Kind: String, Codable {
        case accepted
        case rejected
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .accepted:
            self = .accepted(try container.decode(VideoStreamDescriptor.self, forKey: .stream))
        case .rejected:
            self = .rejected(
                id: try container.decode(VideoSubscriptionID.self, forKey: .id),
                reason: try container.decode(VideoSubscriptionRejection.self, forKey: .reason)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accepted(let stream):
            try container.encode(Kind.accepted, forKey: .type)
            try container.encode(stream, forKey: .stream)
        case .rejected(let id, let reason):
            try container.encode(Kind.rejected, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(reason, forKey: .reason)
        }
    }
}

extension VideoControlMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case subscription
        case unsubscribe
        case feedback
    }

    private enum Kind: String, Codable {
        case subscribe
        case unsubscribe
        case feedback
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .subscribe:
            self = .subscribe(
                try container.decode(VideoSubscriptionRequest.self, forKey: .subscription)
            )
        case .unsubscribe:
            self = .unsubscribe(
                try container.decode(VideoUnsubscribeRequest.self, forKey: .unsubscribe)
            )
        case .feedback:
            self = .feedback(
                try container.decode(VideoReceiverFeedback.self, forKey: .feedback)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .subscribe(let subscription):
            try container.encode(Kind.subscribe, forKey: .type)
            try container.encode(subscription, forKey: .subscription)
        case .unsubscribe(let unsubscribe):
            try container.encode(Kind.unsubscribe, forKey: .type)
            try container.encode(unsubscribe, forKey: .unsubscribe)
        case .feedback(let feedback):
            try container.encode(Kind.feedback, forKey: .type)
            try container.encode(feedback, forKey: .feedback)
        }
    }
}

public enum VideoEvent: Equatable, Sendable {
    case subscription(VideoSubscriptionResponse)
    case ended(id: VideoSubscriptionID, reason: String)
}
