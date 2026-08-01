import Foundation

public typealias RobotVideoDataStream = AsyncThrowingStream<VideoDataMessage, any Error>

/// An opened video-data channel. The opaque ID is unique per open operation, so delayed cleanup
/// from an old connection or an earlier subscription cannot close a newer channel that happens to
/// reuse the same subscription ID.
public struct RobotVideoDataChannel: Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let descriptor: VideoStreamDescriptor
    public let messages: RobotVideoDataStream

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        descriptor: VideoStreamDescriptor,
        messages: RobotVideoDataStream
    ) {
        self.id = id
        self.sessionID = sessionID
        self.descriptor = descriptor
        self.messages = messages
    }
}

/// A separate data plane for encoded video. Control and safety commands never flow through this
/// interface, so video backpressure cannot delay motion or emergency-stop traffic.
public protocol RobotVideoDataTransport: Sendable {
    func openVideoDataStream(
        sessionID: UUID,
        stream: VideoStreamDescriptor
    ) async throws -> RobotVideoDataChannel

    func closeVideoDataChannel(_ id: UUID) async
}

/// Injection point used by the deterministic robot transport to host a platform-specific camera
/// producer without importing media frameworks into `ROBControlCore`.
public protocol RobotVideoDataSource: Sendable {
    var supportedCodecs: Set<VideoCodec> { get }
    var supportedDeliveryModes: Set<VideoDeliveryMode> { get }
    var maximumBitrate: UInt32 { get }

    func openVideoDataStream(
        sessionID: UUID,
        stream: VideoStreamDescriptor
    ) async throws -> RobotVideoDataChannel

    func closeVideoDataChannel(_ id: UUID) async
    func closeVideoDataStreams(sessionID: UUID, subscriptionID: VideoSubscriptionID) async
    func closeAllVideoDataStreams(sessionID: UUID) async
    func handleVideoFeedback(_ feedback: VideoReceiverFeedback, sessionID: UUID) async
}

public enum VideoDataTransportError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case inactiveSession
    case subscriptionNotFound(VideoSubscriptionID)
    case channelSuperseded
    case channelMetadataMismatch

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "The connected robot does not provide an encoded-video data channel."
        case .inactiveSession:
            "The video data channel belongs to an inactive robot session."
        case .subscriptionNotFound(let id):
            "No accepted video subscription exists for \(id.rawValue)."
        case .channelSuperseded:
            "The video data channel was superseded before it finished opening."
        case .channelMetadataMismatch:
            "The video data transport returned a channel with unexpected session or stream metadata."
        }
    }
}
