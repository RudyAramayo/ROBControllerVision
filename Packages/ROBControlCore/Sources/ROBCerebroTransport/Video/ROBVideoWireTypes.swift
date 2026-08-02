import Foundation
import ROBControlCore

/// Constants for Cerebro's current, reliable-stream-only video service.
public enum ROBCerebroVideoProtocol {
    public static let serviceType = "_robvideo._udp"
    public static let applicationProtocol = "robvideo/1"
    public static let protocolVersion: UInt8 = 1
    public static let defaultPort: UInt16 = 12_346

    public static let maximumControlMessageBytes = 64 * 1_024
    public static let maximumAccessUnitBytes = 2 * 1_024 * 1_024
    public static let maximumCodecConfigurationBytes = 64 * 1_024
    public static let maximumFramedPayloadBytes = maximumAccessUnitBytes + 92

    public static let maximumWidth: UInt16 = 960
    public static let maximumHeight: UInt16 = 540
    public static let maximumFramesPerSecond: UInt16 = 20
    public static let maximumBitrate: UInt32 = 1_500_000
    public static let minimumBitrate: UInt32 = 250_000
}

/// One camera advertised by Cerebro after `robvideo/1` authentication.
public struct ROBCerebroVideoCameraCapability: Hashable, Sendable {
    public let id: CameraID
    public let name: String
    public let supportedCodecs: [VideoCodec]
    public let supportedDeliveryModes: [VideoDeliveryMode]
    public let maximumWidth: UInt16
    public let maximumHeight: UInt16
    public let maximumFramesPerSecond: UInt16
    public let maximumBitrate: UInt32

    public var cameraDescriptor: CameraDescriptor {
        CameraDescriptor(
            id: id,
            name: name,
            supportedCodecs: supportedCodecs,
            maximumWidth: maximumWidth,
            maximumHeight: maximumHeight,
            maximumFramesPerSecond: maximumFramesPerSecond
        )
    }
}

/// The one-time capabilities message sent on an authenticated video connection.
public struct ROBCerebroVideoCapabilities: Hashable, Sendable {
    public let protocolVersion: UInt8
    public let cameras: [ROBCerebroVideoCameraCapability]

    public var cameraDescriptors: [CameraDescriptor] {
        cameras.map(\.cameraDescriptor)
    }
}

/// Application messages received after video authentication and capabilities negotiation.
public enum ROBVideoInboundMessage: Sendable {
    case subscriptionResponse(sessionID: UUID, response: VideoSubscriptionResponse)
    case videoData(VideoDataMessage)
    case streamEnded(sessionID: UUID, id: VideoSubscriptionID, reason: String)
}

enum ROBVideoMessageType: UInt16, Sendable {
    case invalid = 0
    case authenticationChallenge = 1
    case authenticationProof = 2
    case authenticationAccepted = 3
    case authenticationRejected = 4
    case capabilities = 5
    case subscribe = 6
    case subscriptionResponse = 7
    case unsubscribe = 8
    case feedback = 9
    case codecConfiguration = 10
    case accessUnit = 11
    case streamEnded = 12

    var isMedia: Bool {
        self == .codecConfiguration || self == .accessUnit
    }
}

enum ROBVideoJSONCodec {
    static func encode<T: Encodable & Sendable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard !data.isEmpty,
            data.count <= ROBCerebroVideoProtocol.maximumControlMessageBytes
        else {
            throw ROBCerebroTransportError.invalidWireMessage
        }
        return data
    }

    static func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) throws -> T {
        guard !data.isEmpty,
            data.count <= ROBCerebroVideoProtocol.maximumControlMessageBytes
        else {
            throw ROBCerebroTransportError.invalidWireMessage
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ROBCerebroTransportError.invalidWireMessage
        }
    }
}

private struct ROBVideoArbitraryCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownVideoKeys<Key>(
    from decoder: any Decoder,
    allowed: Key.Type
) throws where Key: CodingKey & CaseIterable {
    let container = try decoder.container(keyedBy: ROBVideoArbitraryCodingKey.self)
    let allowedNames = Set(Key.allCases.map(\.stringValue))
    guard container.allKeys.allSatisfy({ allowedNames.contains($0.stringValue) }) else {
        throw ROBCerebroTransportError.invalidWireMessage
    }
}

struct ROBVideoWireCameraDescriptor: Codable, Sendable {
    let id: String
    let name: String
    let supportedCodecs: [VideoCodec]
    let supportedDeliveryModes: [VideoDeliveryMode]
    let maximumWidth: UInt16
    let maximumHeight: UInt16
    let maximumFramesPerSecond: UInt16
    let maximumBitrate: UInt32

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case name
        case supportedCodecs
        case supportedDeliveryModes
        case maximumWidth
        case maximumHeight
        case maximumFramesPerSecond
        case maximumBitrate
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownVideoKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        supportedCodecs = try container.decode([VideoCodec].self, forKey: .supportedCodecs)
        supportedDeliveryModes = try container.decode(
            [VideoDeliveryMode].self,
            forKey: .supportedDeliveryModes
        )
        maximumWidth = try container.decode(UInt16.self, forKey: .maximumWidth)
        maximumHeight = try container.decode(UInt16.self, forKey: .maximumHeight)
        maximumFramesPerSecond = try container.decode(
            UInt16.self,
            forKey: .maximumFramesPerSecond
        )
        maximumBitrate = try container.decode(UInt32.self, forKey: .maximumBitrate)
    }

    func mapped() throws -> ROBCerebroVideoCameraCapability {
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty,
            cleanID.utf8.count <= 128,
            !cleanName.isEmpty,
            cleanName.utf8.count <= 256,
            !supportedCodecs.isEmpty,
            !supportedDeliveryModes.isEmpty,
            maximumWidth > 0,
            maximumHeight > 0,
            maximumFramesPerSecond > 0,
            maximumBitrate > 0,
            maximumWidth <= ROBCerebroVideoProtocol.maximumWidth,
            maximumHeight <= ROBCerebroVideoProtocol.maximumHeight,
            maximumFramesPerSecond <= ROBCerebroVideoProtocol.maximumFramesPerSecond,
            maximumBitrate <= ROBCerebroVideoProtocol.maximumBitrate,
            supportedCodecs.contains(.h264),
            supportedDeliveryModes.contains(.reliableStream)
        else {
            throw ROBCerebroTransportError.invalidWireMessage
        }
        return ROBCerebroVideoCameraCapability(
            id: CameraID(rawValue: cleanID),
            name: cleanName,
            supportedCodecs: supportedCodecs,
            supportedDeliveryModes: supportedDeliveryModes,
            maximumWidth: maximumWidth,
            maximumHeight: maximumHeight,
            maximumFramesPerSecond: maximumFramesPerSecond,
            maximumBitrate: maximumBitrate
        )
    }
}

struct ROBVideoWireCapabilities: Codable, Sendable {
    let protocolVersion: UInt8
    let cameras: [ROBVideoWireCameraDescriptor]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion
        case cameras
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownVideoKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(UInt8.self, forKey: .protocolVersion)
        cameras = try container.decode([ROBVideoWireCameraDescriptor].self, forKey: .cameras)
    }

    func mapped() throws -> ROBCerebroVideoCapabilities {
        guard protocolVersion == ROBCerebroVideoProtocol.protocolVersion,
            cameras.count <= 16
        else {
            throw ROBCerebroTransportError.invalidWireMessage
        }
        let mapped = try cameras.map { try $0.mapped() }
        guard Set(mapped.map(\.id)).count == mapped.count else {
            throw ROBCerebroTransportError.invalidWireMessage
        }
        return ROBCerebroVideoCapabilities(
            protocolVersion: protocolVersion,
            cameras: mapped
        )
    }
}

struct ROBVideoWireConstraints: Codable, Sendable {
    let maximumWidth: UInt16
    let maximumHeight: UInt16
    let maximumFramesPerSecond: UInt16
    let maximumBitrate: UInt32

    init(_ constraints: VideoConstraints) throws {
        guard constraints.isValid,
            Int(constraints.maximumWidth) <= VideoDataChannelLimits.hardMaximumVideoDimension,
            Int(constraints.maximumHeight) <= VideoDataChannelLimits.hardMaximumVideoDimension,
            Int(constraints.maximumWidth) * Int(constraints.maximumHeight)
                <= VideoDataChannelLimits.hardMaximumDecodedPixels,
            Int(constraints.maximumFramesPerSecond)
                <= VideoDataChannelLimits.hardMaximumFramesPerSecond,
            constraints.maximumBitrate <= VideoDataChannelLimits.hardMaximumBitrate
        else {
            throw ROBCerebroTransportError.invalidWireMessage
        }
        maximumWidth = constraints.maximumWidth
        maximumHeight = constraints.maximumHeight
        maximumFramesPerSecond = constraints.maximumFramesPerSecond
        maximumBitrate = constraints.maximumBitrate
    }
}

struct ROBVideoWireSubscriptionRequest: Codable, Sendable {
    let protocolVersion: UInt8
    let sessionID: UUID
    let id: UUID
    let cameraID: String
    let preferredCodecs: [VideoCodec]
    let constraints: ROBVideoWireConstraints
    let delivery: VideoDeliveryMode

    init(sessionID: UUID, request: VideoSubscriptionRequest) throws {
        guard request.delivery == .reliableStream,
            request.preferredCodecs.contains(.h264),
            !request.cameraID.rawValue.isEmpty,
            request.cameraID.rawValue.utf8.count <= 128
        else {
            throw ROBCerebroTransportError.protocolMismatch(
                "Cerebro currently supports H.264 reliableStream video only."
            )
        }
        protocolVersion = ROBCerebroVideoProtocol.protocolVersion
        self.sessionID = sessionID
        id = request.id.rawValue
        cameraID = request.cameraID.rawValue
        preferredCodecs = request.preferredCodecs
        constraints = try ROBVideoWireConstraints(request.constraints)
        delivery = request.delivery
    }
}

struct ROBVideoWireStreamDescriptor: Codable, Sendable {
    let sessionID: UUID
    let id: UUID
    let cameraID: String
    let codec: VideoCodec
    let width: UInt16
    let height: UInt16
    let framesPerSecond: UInt16
    let bitrate: UInt32
    let delivery: VideoDeliveryMode

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionID
        case id
        case cameraID
        case codec
        case width
        case height
        case framesPerSecond
        case bitrate
        case delivery
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownVideoKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        id = try container.decode(UUID.self, forKey: .id)
        cameraID = try container.decode(String.self, forKey: .cameraID)
        codec = try container.decode(VideoCodec.self, forKey: .codec)
        width = try container.decode(UInt16.self, forKey: .width)
        height = try container.decode(UInt16.self, forKey: .height)
        framesPerSecond = try container.decode(UInt16.self, forKey: .framesPerSecond)
        bitrate = try container.decode(UInt32.self, forKey: .bitrate)
        delivery = try container.decode(VideoDeliveryMode.self, forKey: .delivery)
    }

    func mapped() throws -> VideoStreamDescriptor {
        guard !cameraID.isEmpty,
            cameraID.utf8.count <= 128,
            codec == .h264,
            delivery == .reliableStream,
            width >= 160,
            height >= 90,
            width <= ROBCerebroVideoProtocol.maximumWidth,
            height <= ROBCerebroVideoProtocol.maximumHeight,
            framesPerSecond > 0,
            framesPerSecond <= ROBCerebroVideoProtocol.maximumFramesPerSecond,
            bitrate >= ROBCerebroVideoProtocol.minimumBitrate,
            bitrate <= ROBCerebroVideoProtocol.maximumBitrate
        else {
            throw ROBCerebroTransportError.invalidWireMessage
        }
        let stream = VideoStreamDescriptor(
            id: VideoSubscriptionID(rawValue: id),
            cameraID: CameraID(rawValue: cameraID),
            codec: codec,
            width: width,
            height: height,
            framesPerSecond: framesPerSecond,
            bitrate: bitrate,
            delivery: delivery
        )
        do {
            try stream.validateForVideoDataChannel()
        } catch {
            throw ROBCerebroTransportError.invalidWireMessage
        }
        return stream
    }
}

struct ROBVideoWireSubscriptionResponse: Decodable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case accepted
        case rejected
    }

    let kind: Kind
    let stream: ROBVideoWireStreamDescriptor?
    let sessionID: UUID?
    let id: UUID?
    let reason: VideoSubscriptionRejection?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case type
        case stream
        case sessionID
        case id
        case reason
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownVideoKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .accepted:
            guard container.contains(.stream),
                !container.contains(.sessionID),
                !container.contains(.id),
                !container.contains(.reason)
            else {
                throw ROBCerebroTransportError.invalidWireMessage
            }
            stream = try container.decode(ROBVideoWireStreamDescriptor.self, forKey: .stream)
            sessionID = nil
            id = nil
            reason = nil
        case .rejected:
            guard !container.contains(.stream),
                container.contains(.sessionID),
                container.contains(.id),
                container.contains(.reason)
            else {
                throw ROBCerebroTransportError.invalidWireMessage
            }
            stream = nil
            sessionID = try container.decode(UUID.self, forKey: .sessionID)
            id = try container.decode(UUID.self, forKey: .id)
            reason = try container.decode(VideoSubscriptionRejection.self, forKey: .reason)
        }
    }

    func mapped() throws -> (sessionID: UUID, response: VideoSubscriptionResponse) {
        switch kind {
        case .accepted:
            guard let stream else { throw ROBCerebroTransportError.invalidWireMessage }
            return (stream.sessionID, .accepted(try stream.mapped()))
        case .rejected:
            guard let sessionID, let id, let reason else {
                throw ROBCerebroTransportError.invalidWireMessage
            }
            return (
                sessionID,
                .rejected(id: VideoSubscriptionID(rawValue: id), reason: reason)
            )
        }
    }
}

struct ROBVideoWireUnsubscribeRequest: Encodable, Sendable {
    let protocolVersion = ROBCerebroVideoProtocol.protocolVersion
    let sessionID: UUID
    let id: UUID

    init(sessionID: UUID, id: VideoSubscriptionID) {
        self.sessionID = sessionID
        self.id = id.rawValue
    }
}

struct ROBVideoWireReceiverFeedback: Encodable, Sendable {
    let protocolVersion = ROBCerebroVideoProtocol.protocolVersion
    let sessionID: UUID
    let id: UUID
    let estimatedPacketLoss: Double
    let estimatedJitterMilliseconds: Double
    let decodedFramesPerSecond: Double
    let desiredBitrate: UInt32?
    let requestsKeyFrame: Bool

    init(sessionID: UUID, feedback: VideoReceiverFeedback) {
        self.sessionID = sessionID
        id = feedback.id.rawValue
        estimatedPacketLoss = feedback.estimatedPacketLoss
        estimatedJitterMilliseconds = feedback.estimatedJitterMilliseconds
        decodedFramesPerSecond = feedback.decodedFramesPerSecond
        desiredBitrate = feedback.desiredBitrate
        requestsKeyFrame = feedback.requestsKeyFrame
    }
}

struct ROBVideoWireStreamEnded: Decodable, Sendable {
    let protocolVersion: UInt8
    let sessionID: UUID
    let id: UUID
    let reason: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion
        case sessionID
        case id
        case reason
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownVideoKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(UInt8.self, forKey: .protocolVersion)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        id = try container.decode(UUID.self, forKey: .id)
        reason = String(try container.decode(String.self, forKey: .reason).prefix(256))
        guard protocolVersion == ROBCerebroVideoProtocol.protocolVersion else {
            throw ROBCerebroTransportError.invalidWireMessage
        }
    }
}

private enum ROBVideoBinaryKind: UInt8 {
    case codecConfiguration = 1
    case accessUnit = 2
}

private enum ROBVideoParameterSetBinaryKind: UInt8 {
    case vps = 1
    case sps = 2
    case pps = 3

    var mapped: VideoCodecParameterSetKind {
        switch self {
        case .vps: .vps
        case .sps: .sps
        case .pps: .pps
        }
    }
}

private struct ROBVideoBinaryHeader {
    static let encodedSize = 92
    static let magic: UInt32 = 0x5242_5644  // RBVD

    let kind: ROBVideoBinaryKind
    let codec: VideoCodec
    let isKeyFrame: Bool
    let payloadLength: UInt32
    let sessionID: UUID
    let streamID: VideoSubscriptionID
    let sequence: UInt64
    let captureTimestampUnixMilliseconds: UInt64
    let presentationTimestamp: UInt64
    let duration: UInt64
    let timescale: UInt32
    let configurationGeneration: UInt32
    let nalLengthFieldBytes: UInt8
    let parameterSetCount: UInt8

    init(_ input: Data) throws {
        let data = Data(input)
        guard data.count >= Self.encodedSize,
            data.readUInt32BigEndian(at: 0) == Self.magic,
            data[4] == ROBCerebroVideoProtocol.protocolVersion,
            let kind = ROBVideoBinaryKind(rawValue: data[5]),
            let codec = VideoCodec(robVideoBinaryValue: data[6]),
            data.readUInt16BigEndian(at: 8) == UInt16(Self.encodedSize),
            data.readUInt16BigEndian(at: 10) == 0,
            data.readUInt16BigEndian(at: 90) == 0,
            let sessionID = UUID(robVideoBytes: Data(data[16..<32])),
            let streamUUID = UUID(robVideoBytes: Data(data[32..<48]))
        else {
            throw ROBCerebroTransportError.invalidWireMessage
        }
        let flags = data[7]
        guard flags & 0xFE == 0 else {
            throw ROBCerebroTransportError.invalidWireMessage
        }
        let payloadLength = data.readUInt32BigEndian(at: 12)
        guard payloadLength <= UInt32(ROBCerebroVideoProtocol.maximumAccessUnitBytes),
            data.count == Self.encodedSize + Int(payloadLength)
        else {
            throw ROBCerebroTransportError.invalidWireMessage
        }

        self.kind = kind
        self.codec = codec
        isKeyFrame = flags & 1 == 1
        self.payloadLength = payloadLength
        self.sessionID = sessionID
        streamID = VideoSubscriptionID(rawValue: streamUUID)
        sequence = data.readUInt64BigEndian(at: 48)
        captureTimestampUnixMilliseconds = data.readUInt64BigEndian(at: 56)
        presentationTimestamp = data.readUInt64BigEndian(at: 64)
        duration = data.readUInt64BigEndian(at: 72)
        timescale = data.readUInt32BigEndian(at: 80)
        configurationGeneration = data.readUInt32BigEndian(at: 84)
        nalLengthFieldBytes = data[88]
        parameterSetCount = data[89]
    }
}

/// Stateful decoder for Cerebro's fixed-width `RBVD` media envelope.
///
/// The decoder is intentionally bound to one accepted session and subscription. It validates the
/// per-access-unit NAL-length width, which is present on Cerebro's wire but not stored by
/// `EncodedVideoAccessUnit`, before adapting the payload into `ROBControlCore`.
public struct ROBVideoBinaryDecoder: Sendable {
    public let sessionID: UUID
    public let stream: VideoStreamDescriptor

    private var configuration: VideoCodecConfiguration?
    private var configurationNALLengthFieldBytes: UInt8?

    public init(sessionID: UUID, stream: VideoStreamDescriptor) throws {
        guard stream.codec == .h264, stream.delivery == .reliableStream else {
            throw ROBCerebroTransportError.protocolMismatch(
                "Cerebro currently sends H.264 reliableStream media only."
            )
        }
        do {
            try stream.validateForVideoDataChannel()
        } catch {
            throw ROBCerebroTransportError.invalidWireMessage
        }
        self.sessionID = sessionID
        self.stream = stream
    }

    public mutating func resetDecoderConfiguration() {
        configuration = nil
        configurationNALLengthFieldBytes = nil
    }

    public mutating func decode(_ input: Data) throws -> VideoDataMessage {
        let data = Data(input)
        let header = try ROBVideoBinaryHeader(data)
        guard header.sessionID == sessionID,
            header.streamID == stream.id,
            header.codec == stream.codec
        else {
            throw ROBCerebroTransportError.invalidWireMessage
        }
        let payload = Data(data.dropFirst(ROBVideoBinaryHeader.encodedSize))

        switch header.kind {
        case .codecConfiguration:
            let decoded = try decodeConfiguration(header: header, payload: payload)
            if let configuration {
                guard decoded.generation >= configuration.generation else {
                    throw ROBCerebroTransportError.invalidWireMessage
                }
                if decoded.generation == configuration.generation {
                    guard decoded == configuration,
                        header.nalLengthFieldBytes == configurationNALLengthFieldBytes
                    else {
                        throw ROBCerebroTransportError.invalidWireMessage
                    }
                }
            }
            configuration = decoded
            configurationNALLengthFieldBytes = header.nalLengthFieldBytes
            return .codecConfiguration(decoded)

        case .accessUnit:
            guard let configuration,
                header.configurationGeneration == configuration.generation,
                header.nalLengthFieldBytes == configurationNALLengthFieldBytes
            else {
                throw ROBCerebroTransportError.invalidWireMessage
            }
            return .accessUnit(try decodeAccessUnit(header: header, payload: payload))
        }
    }

    private func decodeConfiguration(
        header: ROBVideoBinaryHeader,
        payload: Data
    ) throws -> VideoCodecConfiguration {
        guard header.sequence == 0,
            header.captureTimestampUnixMilliseconds == 0,
            header.presentationTimestamp == 0,
            header.duration == 0,
            header.timescale == 0,
            !header.isKeyFrame,
            header.codec != .jpeg,
            header.configurationGeneration > 0,
            [1, 2, 4].contains(header.nalLengthFieldBytes),
            header.parameterSetCount > 0,
            header.parameterSetCount <= 16,
            payload.count <= ROBCerebroVideoProtocol.maximumCodecConfigurationBytes + (16 * 8)
        else {
            throw ROBCerebroTransportError.invalidWireMessage
        }

        var offset = 0
        var rawByteCount = 0
        var parameterSets: [VideoCodecParameterSet] = []
        parameterSets.reserveCapacity(Int(header.parameterSetCount))
        for _ in 0..<Int(header.parameterSetCount) {
            guard payload.count - offset >= 8,
                let kind = ROBVideoParameterSetBinaryKind(rawValue: payload[offset]),
                payload[offset + 1] == 0,
                payload[offset + 2] == 0,
                payload[offset + 3] == 0
            else {
                throw ROBCerebroTransportError.invalidWireMessage
            }
            let length = Int(payload.readUInt32BigEndian(at: offset + 4))
            offset += 8
            guard length > 0,
                length <= ROBCerebroVideoProtocol.maximumCodecConfigurationBytes,
                length <= payload.count - offset
            else {
                throw ROBCerebroTransportError.invalidWireMessage
            }
            let bytes = Data(payload[offset..<(offset + length)])
            try validateParameterSet(bytes, kind: kind, codec: header.codec)
            rawByteCount += length
            guard rawByteCount <= ROBCerebroVideoProtocol.maximumCodecConfigurationBytes else {
                throw ROBCerebroTransportError.invalidWireMessage
            }
            do {
                parameterSets.append(
                    try VideoCodecParameterSet(kind: kind.mapped, bytes: bytes)
                )
            } catch {
                throw ROBCerebroTransportError.invalidWireMessage
            }
            offset += length
        }
        guard offset == payload.count else {
            throw ROBCerebroTransportError.invalidWireMessage
        }

        do {
            return try VideoCodecConfiguration(
                sessionID: header.sessionID,
                streamID: header.streamID,
                codec: header.codec,
                generation: header.configurationGeneration,
                parameterSets: parameterSets,
                nalLengthFieldBytes: header.nalLengthFieldBytes
            )
        } catch {
            throw ROBCerebroTransportError.invalidWireMessage
        }
    }

    private func decodeAccessUnit(
        header: ROBVideoBinaryHeader,
        payload: Data
    ) throws -> EncodedVideoAccessUnit {
        guard header.parameterSetCount == 0,
            header.codec == .h264 || header.codec == .hevc,
            header.sequence > 0,
            header.captureTimestampUnixMilliseconds <= UInt64(Int64.max),
            header.presentationTimestamp <= UInt64(Int64.max),
            header.duration > 0,
            header.duration <= UInt64(Int64.max),
            header.timescale > 0,
            header.timescale <= 1_000_000_000,
            header.timescale <= UInt32(Int32.max),
            header.duration <= UInt64(header.timescale) * 10,
            header.configurationGeneration > 0,
            [1, 2, 4].contains(header.nalLengthFieldBytes),
            !payload.isEmpty,
            payload.count <= ROBCerebroVideoProtocol.maximumAccessUnitBytes
        else {
            throw ROBCerebroTransportError.invalidWireMessage
        }
        try validateAccessUnitNALs(
            payload,
            codec: header.codec,
            nalLengthFieldBytes: header.nalLengthFieldBytes,
            isKeyFrame: header.isKeyFrame
        )

        do {
            return try EncodedVideoAccessUnit(
                sessionID: header.sessionID,
                streamID: header.streamID,
                codec: header.codec,
                sequence: header.sequence,
                captureTimestampUnixMilliseconds: Int64(header.captureTimestampUnixMilliseconds),
                presentationTimestamp: Int64(header.presentationTimestamp),
                duration: Int64(header.duration),
                timescale: Int32(header.timescale),
                isKeyFrame: header.isKeyFrame,
                codecConfigurationGeneration: header.configurationGeneration,
                payload: payload
            )
        } catch {
            throw ROBCerebroTransportError.invalidWireMessage
        }
    }

    private func validateParameterSet(
        _ bytes: Data,
        kind: ROBVideoParameterSetBinaryKind,
        codec: VideoCodec
    ) throws {
        guard let first = bytes.first, first & 0x80 == 0 else {
            throw ROBCerebroTransportError.invalidWireMessage
        }
        switch codec {
        case .h264:
            let nalType = first & 0x1F
            guard (kind == .sps && nalType == 7) || (kind == .pps && nalType == 8) else {
                throw ROBCerebroTransportError.invalidWireMessage
            }
        case .hevc:
            guard bytes.count >= 2, bytes[bytes.index(after: bytes.startIndex)] & 0x07 != 0 else {
                throw ROBCerebroTransportError.invalidWireMessage
            }
            let nalType = (first >> 1) & 0x3F
            let matches =
                (kind == .vps && nalType == 32)
                || (kind == .sps && nalType == 33)
                || (kind == .pps && nalType == 34)
            guard matches else { throw ROBCerebroTransportError.invalidWireMessage }
        case .jpeg:
            throw ROBCerebroTransportError.invalidWireMessage
        }
    }

    private func validateAccessUnitNALs(
        _ payload: Data,
        codec: VideoCodec,
        nalLengthFieldBytes: UInt8,
        isKeyFrame: Bool
    ) throws {
        let prefixLength = Int(nalLengthFieldBytes)
        var offset = 0
        var containsVideoCodingLayer = false
        var containsKeyFrame = false

        while offset < payload.count {
            guard payload.count - offset >= prefixLength else {
                throw ROBCerebroTransportError.invalidWireMessage
            }
            var length = 0
            for byte in payload[offset..<(offset + prefixLength)] {
                length = (length << 8) | Int(byte)
            }
            offset += prefixLength
            guard length > 0, length <= payload.count - offset else {
                throw ROBCerebroTransportError.invalidWireMessage
            }
            let first = payload[offset]
            guard first & 0x80 == 0 else {
                throw ROBCerebroTransportError.invalidWireMessage
            }
            let type: UInt8
            switch codec {
            case .h264:
                type = first & 0x1F
                containsVideoCodingLayer = containsVideoCodingLayer || (1...5).contains(type)
                containsKeyFrame = containsKeyFrame || type == 5
            case .hevc:
                guard length >= 2, payload[offset + 1] & 0x07 != 0 else {
                    throw ROBCerebroTransportError.invalidWireMessage
                }
                type = (first >> 1) & 0x3F
                containsVideoCodingLayer = containsVideoCodingLayer || (0...31).contains(type)
                containsKeyFrame = containsKeyFrame || (16...23).contains(type)
            case .jpeg:
                throw ROBCerebroTransportError.invalidWireMessage
            }
            offset += length
        }
        guard offset == payload.count,
            containsVideoCodingLayer,
            containsKeyFrame == isKeyFrame
        else {
            throw ROBCerebroTransportError.invalidWireMessage
        }
    }
}

extension VideoCodec {
    fileprivate init?(robVideoBinaryValue: UInt8) {
        switch robVideoBinaryValue {
        case 1: self = .jpeg
        case 2: self = .h264
        case 3: self = .hevc
        default: return nil
        }
    }
}

extension UUID {
    var robVideoBytes: Data {
        var value = uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    init?(robVideoBytes data: Data) {
        guard data.count == 16 else { return nil }
        var value: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0) }
        self.init(uuid: value)
    }
}

extension Data {
    func readUInt16BigEndian(at offset: Int) -> UInt16 {
        let index = startIndex + offset
        return (UInt16(self[index]) << 8) | UInt16(self[index + 1])
    }

    func readUInt32BigEndian(at offset: Int) -> UInt32 {
        let index = startIndex + offset
        var value: UInt32 = 0
        for byte in self[index..<(index + 4)] {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    func readUInt64BigEndian(at offset: Int) -> UInt64 {
        let index = startIndex + offset
        var value: UInt64 = 0
        for byte in self[index..<(index + 8)] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    mutating func appendUInt16BigEndian(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32BigEndian(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }

    mutating func appendUInt64BigEndian(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}
