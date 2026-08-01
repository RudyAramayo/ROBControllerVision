import Foundation

/// Local policy limits for the encoded-video data channel.
///
/// The hard maxima are also enforced by direct `Codable` decoding. A transport may use lower
/// limits by constructing a custom value and passing it to `VideoDataMessageCodec` and
/// `VideoStreamValidator`.
public struct VideoDataChannelLimits: Equatable, Sendable {
    public static let hardMaximumAccessUnitBytes = 2 * 1_024 * 1_024
    public static let hardMaximumCodecConfigurationBytes = 64 * 1_024
    public static let hardMaximumSerializedMessageBytes = 3 * 1_024 * 1_024
    public static let hardMaximumVideoDimension = 4_096
    public static let hardMaximumDecodedPixels = 4_096 * 2_160
    public static let hardMaximumFramesPerSecond = 240
    public static let hardMaximumBitrate: UInt32 = 1_000_000_000

    public static let standard = VideoDataChannelLimits(
        uncheckedMaximumAccessUnitBytes: hardMaximumAccessUnitBytes,
        maximumCodecConfigurationBytes: hardMaximumCodecConfigurationBytes,
        maximumSerializedMessageBytes: hardMaximumSerializedMessageBytes
    )

    public let maximumAccessUnitBytes: Int
    public let maximumCodecConfigurationBytes: Int
    public let maximumSerializedMessageBytes: Int

    public init(
        maximumAccessUnitBytes: Int = hardMaximumAccessUnitBytes,
        maximumCodecConfigurationBytes: Int = hardMaximumCodecConfigurationBytes,
        maximumSerializedMessageBytes: Int = hardMaximumSerializedMessageBytes
    ) throws {
        try Self.validateLimit(
            maximumAccessUnitBytes,
            name: "maximumAccessUnitBytes",
            hardMaximum: Self.hardMaximumAccessUnitBytes
        )
        try Self.validateLimit(
            maximumCodecConfigurationBytes,
            name: "maximumCodecConfigurationBytes",
            hardMaximum: Self.hardMaximumCodecConfigurationBytes
        )
        try Self.validateLimit(
            maximumSerializedMessageBytes,
            name: "maximumSerializedMessageBytes",
            hardMaximum: Self.hardMaximumSerializedMessageBytes
        )

        self.maximumAccessUnitBytes = maximumAccessUnitBytes
        self.maximumCodecConfigurationBytes = maximumCodecConfigurationBytes
        self.maximumSerializedMessageBytes = maximumSerializedMessageBytes
    }

    private init(
        uncheckedMaximumAccessUnitBytes: Int,
        maximumCodecConfigurationBytes: Int,
        maximumSerializedMessageBytes: Int
    ) {
        maximumAccessUnitBytes = uncheckedMaximumAccessUnitBytes
        self.maximumCodecConfigurationBytes = maximumCodecConfigurationBytes
        self.maximumSerializedMessageBytes = maximumSerializedMessageBytes
    }

    private static func validateLimit(_ value: Int, name: String, hardMaximum: Int) throws {
        guard value > 0, value <= hardMaximum else {
            throw VideoDataValidationError.invalidLimit(
                name: name,
                value: value,
                hardMaximum: hardMaximum
            )
        }
    }
}

extension VideoStreamDescriptor {
    /// Validates negotiated media properties before a source allocates buffers or a receiver
    /// constructs a decoder format description.
    public func validateForVideoDataChannel() throws {
        guard width > 0,
            height > 0,
            framesPerSecond > 0,
            bitrate > 0,
            Int(width) <= VideoDataChannelLimits.hardMaximumVideoDimension,
            Int(height) <= VideoDataChannelLimits.hardMaximumVideoDimension,
            Int(width) * Int(height) <= VideoDataChannelLimits.hardMaximumDecodedPixels,
            Int(framesPerSecond) <= VideoDataChannelLimits.hardMaximumFramesPerSecond,
            bitrate <= VideoDataChannelLimits.hardMaximumBitrate
        else {
            throw VideoDataValidationError.invalidStreamDescriptor
        }
    }
}

public enum VideoCodecParameterSetKind: String, Codable, CaseIterable, Hashable, Sendable {
    case vps
    case sps
    case pps
}

/// A raw H.264 or HEVC parameter-set NAL unit without an Annex-B start code.
public struct VideoCodecParameterSet: Codable, Hashable, Sendable {
    public let kind: VideoCodecParameterSetKind
    public let bytes: Data

    public init(kind: VideoCodecParameterSetKind, bytes: Data) throws {
        guard !bytes.isEmpty else {
            throw VideoDataValidationError.emptyCodecParameterSet(kind: kind)
        }
        guard bytes.count <= VideoDataChannelLimits.hardMaximumCodecConfigurationBytes else {
            throw VideoDataValidationError.codecConfigurationTooLarge(
                actualBytes: bytes.count,
                maximumBytes: VideoDataChannelLimits.hardMaximumCodecConfigurationBytes
            )
        }

        self.kind = kind
        self.bytes = bytes
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case bytes
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(VideoCodecParameterSetKind.self, forKey: .kind),
            bytes: container.decode(Data.self, forKey: .bytes)
        )
    }
}

/// Decoder configuration for one generation of an H.264 or HEVC stream.
///
/// Parameter sets contain raw NAL-unit bytes. Encoded H.264 and HEVC access units use AVCC-style
/// big-endian length prefixes of `nalLengthFieldBytes`; Annex-B start codes are not accepted.
public struct VideoCodecConfiguration: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let streamID: VideoSubscriptionID
    public let codec: VideoCodec
    public let generation: UInt32
    public let parameterSets: [VideoCodecParameterSet]
    public let nalLengthFieldBytes: UInt8

    public init(
        sessionID: UUID,
        streamID: VideoSubscriptionID,
        codec: VideoCodec,
        generation: UInt32,
        parameterSets: [VideoCodecParameterSet],
        nalLengthFieldBytes: UInt8
    ) throws {
        self.sessionID = sessionID
        self.streamID = streamID
        self.codec = codec
        self.generation = generation
        self.parameterSets = parameterSets
        self.nalLengthFieldBytes = nalLengthFieldBytes

        try validate(limits: .standard)
    }

    public func validate(limits: VideoDataChannelLimits = .standard) throws {
        guard codec != .jpeg else {
            throw VideoDataValidationError.codecConfigurationNotAllowed(codec: codec)
        }
        guard generation > 0 else {
            throw VideoDataValidationError.invalidCodecConfigurationGeneration(generation)
        }
        guard [1, 2, 4].contains(nalLengthFieldBytes) else {
            throw VideoDataValidationError.invalidNALLengthFieldBytes(nalLengthFieldBytes)
        }
        guard !parameterSets.isEmpty, parameterSets.count <= 16 else {
            throw VideoDataValidationError.invalidCodecParameterSetCount(parameterSets.count)
        }

        let byteCount = parameterSets.reduce(into: 0) { total, parameterSet in
            total += parameterSet.bytes.count
        }
        guard byteCount <= limits.maximumCodecConfigurationBytes else {
            throw VideoDataValidationError.codecConfigurationTooLarge(
                actualBytes: byteCount,
                maximumBytes: limits.maximumCodecConfigurationBytes
            )
        }

        let availableKinds = Set(parameterSets.map(\.kind))
        switch codec {
        case .h264:
            guard availableKinds.contains(.sps), availableKinds.contains(.pps), !availableKinds.contains(.vps) else {
                throw VideoDataValidationError.missingRequiredCodecParameterSets(codec: codec)
            }
        case .hevc:
            guard availableKinds.contains(.vps), availableKinds.contains(.sps), availableKinds.contains(.pps) else {
                throw VideoDataValidationError.missingRequiredCodecParameterSets(codec: codec)
            }
        case .jpeg:
            throw VideoDataValidationError.codecConfigurationNotAllowed(codec: codec)
        }

        for parameterSet in parameterSets {
            guard Self.parameterSet(parameterSet, matches: codec) else {
                throw VideoDataValidationError.invalidCodecParameterSet(
                    codec: codec,
                    kind: parameterSet.kind
                )
            }
        }
    }

    private static func parameterSet(
        _ parameterSet: VideoCodecParameterSet,
        matches codec: VideoCodec
    ) -> Bool {
        guard let firstByte = parameterSet.bytes.first else { return false }

        switch codec {
        case .h264:
            let nalUnitType = firstByte & 0x1F
            switch parameterSet.kind {
            case .sps: return nalUnitType == 7
            case .pps: return nalUnitType == 8
            case .vps: return false
            }
        case .hevc:
            let nalUnitType = (firstByte >> 1) & 0x3F
            switch parameterSet.kind {
            case .vps: return nalUnitType == 32
            case .sps: return nalUnitType == 33
            case .pps: return nalUnitType == 34
            }
        case .jpeg:
            return false
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionID
        case streamID
        case codec
        case generation
        case parameterSets
        case nalLengthFieldBytes
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionID: container.decode(UUID.self, forKey: .sessionID),
            streamID: container.decode(VideoSubscriptionID.self, forKey: .streamID),
            codec: container.decode(VideoCodec.self, forKey: .codec),
            generation: container.decode(UInt32.self, forKey: .generation),
            parameterSets: container.decode([VideoCodecParameterSet].self, forKey: .parameterSets),
            nalLengthFieldBytes: container.decode(UInt8.self, forKey: .nalLengthFieldBytes)
        )
    }
}

/// One complete compressed video access unit.
///
/// The payload is deliberately not fragmented here. A QUIC, TCP, or UDP adapter may introduce a
/// separate packet/framing layer and must reassemble a complete access unit before constructing
/// this value.
public struct EncodedVideoAccessUnit: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let streamID: VideoSubscriptionID
    public let codec: VideoCodec
    public let sequence: UInt64
    public let captureTimestampUnixMilliseconds: Int64
    public let presentationTimestamp: Int64
    public let duration: Int64
    public let timescale: Int32
    public let isKeyFrame: Bool
    public let codecConfigurationGeneration: UInt32?
    public let payload: Data

    public init(
        sessionID: UUID,
        streamID: VideoSubscriptionID,
        codec: VideoCodec,
        sequence: UInt64,
        captureTimestampUnixMilliseconds: Int64,
        presentationTimestamp: Int64,
        duration: Int64,
        timescale: Int32,
        isKeyFrame: Bool,
        codecConfigurationGeneration: UInt32?,
        payload: Data
    ) throws {
        self.sessionID = sessionID
        self.streamID = streamID
        self.codec = codec
        self.sequence = sequence
        self.captureTimestampUnixMilliseconds = captureTimestampUnixMilliseconds
        self.presentationTimestamp = presentationTimestamp
        self.duration = duration
        self.timescale = timescale
        self.isKeyFrame = isKeyFrame
        self.codecConfigurationGeneration = codecConfigurationGeneration
        self.payload = payload

        try validate(limits: .standard)
    }

    public func validate(limits: VideoDataChannelLimits = .standard) throws {
        guard captureTimestampUnixMilliseconds >= 0 else {
            throw VideoDataValidationError.invalidCaptureTimestamp(captureTimestampUnixMilliseconds)
        }
        guard presentationTimestamp >= 0 else {
            throw VideoDataValidationError.invalidPresentationTimestamp(presentationTimestamp)
        }
        guard duration > 0 else {
            throw VideoDataValidationError.invalidDuration(duration)
        }
        guard timescale > 0, timescale <= 1_000_000_000 else {
            throw VideoDataValidationError.invalidTimescale(timescale)
        }
        guard duration <= Int64(timescale) * 10 else {
            throw VideoDataValidationError.durationExceedsMaximum(duration: duration, timescale: timescale)
        }
        guard !payload.isEmpty else {
            throw VideoDataValidationError.emptyAccessUnit
        }
        guard payload.count <= limits.maximumAccessUnitBytes else {
            throw VideoDataValidationError.accessUnitTooLarge(
                actualBytes: payload.count,
                maximumBytes: limits.maximumAccessUnitBytes
            )
        }

        switch codec {
        case .jpeg:
            guard isKeyFrame, codecConfigurationGeneration == nil else {
                throw VideoDataValidationError.invalidJPEGMetadata
            }
            guard payload.count >= 4,
                payload[payload.startIndex] == 0xFF,
                payload[payload.index(after: payload.startIndex)] == 0xD8,
                payload[payload.index(payload.endIndex, offsetBy: -2)] == 0xFF,
                payload[payload.index(before: payload.endIndex)] == 0xD9
            else {
                throw VideoDataValidationError.invalidJPEGPayload
            }
        case .h264, .hevc:
            guard let generation = codecConfigurationGeneration, generation > 0 else {
                throw VideoDataValidationError.missingCodecConfigurationGeneration
            }
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionID
        case streamID
        case codec
        case sequence
        case captureTimestampUnixMilliseconds
        case presentationTimestamp
        case duration
        case timescale
        case isKeyFrame
        case codecConfigurationGeneration
        case payload
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionID: container.decode(UUID.self, forKey: .sessionID),
            streamID: container.decode(VideoSubscriptionID.self, forKey: .streamID),
            codec: container.decode(VideoCodec.self, forKey: .codec),
            sequence: container.decode(UInt64.self, forKey: .sequence),
            captureTimestampUnixMilliseconds: container.decode(
                Int64.self,
                forKey: .captureTimestampUnixMilliseconds
            ),
            presentationTimestamp: container.decode(Int64.self, forKey: .presentationTimestamp),
            duration: container.decode(Int64.self, forKey: .duration),
            timescale: container.decode(Int32.self, forKey: .timescale),
            isKeyFrame: container.decode(Bool.self, forKey: .isKeyFrame),
            codecConfigurationGeneration: container.decodeIfPresent(
                UInt32.self,
                forKey: .codecConfigurationGeneration
            ),
            payload: container.decode(Data.self, forKey: .payload)
        )
    }
}

/// A versioned message on the encoded-video data channel.
public enum VideoDataMessage: Hashable, Sendable {
    public static let protocolVersion: UInt16 = 1

    case codecConfiguration(VideoCodecConfiguration)
    case accessUnit(EncodedVideoAccessUnit)

    public var sessionID: UUID {
        switch self {
        case .codecConfiguration(let configuration): configuration.sessionID
        case .accessUnit(let accessUnit): accessUnit.sessionID
        }
    }

    public var streamID: VideoSubscriptionID {
        switch self {
        case .codecConfiguration(let configuration): configuration.streamID
        case .accessUnit(let accessUnit): accessUnit.streamID
        }
    }

    public var codec: VideoCodec {
        switch self {
        case .codecConfiguration(let configuration): configuration.codec
        case .accessUnit(let accessUnit): accessUnit.codec
        }
    }

    public func validate(limits: VideoDataChannelLimits = .standard) throws {
        switch self {
        case .codecConfiguration(let configuration):
            try configuration.validate(limits: limits)
        case .accessUnit(let accessUnit):
            try accessUnit.validate(limits: limits)
        }
    }
}

extension VideoDataMessage: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion
        case type
        case codecConfiguration
        case accessUnit
    }

    private enum Kind: String, Codable {
        case codecConfiguration
        case accessUnit
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(UInt16.self, forKey: .protocolVersion)
        guard version == Self.protocolVersion else {
            throw VideoDataValidationError.unsupportedProtocolVersion(version)
        }

        switch try container.decode(Kind.self, forKey: .type) {
        case .codecConfiguration:
            guard container.contains(.codecConfiguration), !container.contains(.accessUnit) else {
                throw VideoDataValidationError.invalidTaggedMessagePayload
            }
            self = .codecConfiguration(
                try container.decode(VideoCodecConfiguration.self, forKey: .codecConfiguration)
            )
        case .accessUnit:
            guard container.contains(.accessUnit), !container.contains(.codecConfiguration) else {
                throw VideoDataValidationError.invalidTaggedMessagePayload
            }
            self = .accessUnit(
                try container.decode(EncodedVideoAccessUnit.self, forKey: .accessUnit)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.protocolVersion, forKey: .protocolVersion)

        switch self {
        case .codecConfiguration(let configuration):
            try container.encode(Kind.codecConfiguration, forKey: .type)
            try container.encode(configuration, forKey: .codecConfiguration)
        case .accessUnit(let accessUnit):
            try container.encode(Kind.accessUnit, forKey: .type)
            try container.encode(accessUnit, forKey: .accessUnit)
        }
    }
}

/// A bounded JSON serializer for adapters that need an initial wire representation.
///
/// Production transports may replace this serializer with a binary representation while retaining
/// the same validated message model. Size is checked before decoding so an attacker cannot force an
/// unbounded base64 allocation through `JSONDecoder`.
public struct VideoDataMessageCodec: Sendable {
    public let limits: VideoDataChannelLimits

    public init(limits: VideoDataChannelLimits = .standard) {
        self.limits = limits
    }

    public func encode(_ message: VideoDataMessage) throws -> Data {
        try message.validate(limits: limits)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(message)
        try validateSerializedSize(data)
        return data
    }

    public func decode(_ data: Data) throws -> VideoDataMessage {
        try validateSerializedSize(data)
        let message = try JSONDecoder().decode(VideoDataMessage.self, from: data)
        try message.validate(limits: limits)
        return message
    }

    private func validateSerializedSize(_ data: Data) throws {
        guard data.count <= limits.maximumSerializedMessageBytes else {
            throw VideoDataValidationError.serializedMessageTooLarge(
                actualBytes: data.count,
                maximumBytes: limits.maximumSerializedMessageBytes
            )
        }
    }
}

/// Stateful validation at the boundary between a data-channel transport and a decoder.
///
/// The validator rejects stale reconnect traffic, cross-stream traffic, out-of-order frames, codec
/// changes outside negotiation, malformed AVCC framing, and delta frames received before a matching
/// configuration and random-access frame.
public struct VideoStreamValidator: Sendable {
    public let sessionID: UUID
    public let stream: VideoStreamDescriptor
    public let limits: VideoDataChannelLimits

    private var currentConfiguration: VideoCodecConfiguration?
    private var lastSequence: UInt64?
    private var lastPresentationTimestamp: Int64?
    private var streamTimescale: Int32?
    private var requiresKeyFrame = true

    public init(
        sessionID: UUID,
        stream: VideoStreamDescriptor,
        limits: VideoDataChannelLimits = .standard
    ) {
        self.sessionID = sessionID
        self.stream = stream
        self.limits = limits
    }

    /// Accepts a validated message and returns an access unit when one is ready for decoding.
    /// Configuration messages update validator state and return `nil`.
    public mutating func accept(_ message: VideoDataMessage) throws -> EncodedVideoAccessUnit? {
        try validateStreamDescriptor()
        try message.validate(limits: limits)

        guard message.sessionID == sessionID else {
            throw VideoDataValidationError.sessionMismatch(
                expected: sessionID,
                received: message.sessionID
            )
        }
        guard message.streamID == stream.id else {
            throw VideoDataValidationError.streamMismatch(
                expected: stream.id,
                received: message.streamID
            )
        }
        guard message.codec == stream.codec else {
            throw VideoDataValidationError.codecMismatch(
                expected: stream.codec,
                received: message.codec
            )
        }

        switch message {
        case .codecConfiguration(let configuration):
            if let currentConfiguration {
                if configuration.generation < currentConfiguration.generation {
                    throw VideoDataValidationError.codecConfigurationGenerationNotIncreasing(
                        previous: currentConfiguration.generation,
                        received: configuration.generation
                    )
                }
                if configuration.generation == currentConfiguration.generation {
                    guard configuration == currentConfiguration else {
                        throw VideoDataValidationError.codecConfigurationGenerationConflict(
                            configuration.generation
                        )
                    }
                    requiresKeyFrame = true
                    return nil
                }
            }
            currentConfiguration = configuration
            requiresKeyFrame = true
            return nil

        case .accessUnit(let accessUnit):
            try validateOrdering(of: accessUnit)
            try validateDecoderReadiness(for: accessUnit)

            lastSequence = accessUnit.sequence
            lastPresentationTimestamp = accessUnit.presentationTimestamp
            streamTimescale = accessUnit.timescale
            if accessUnit.isKeyFrame {
                requiresKeyFrame = false
            }
            return accessUnit
        }
    }

    /// Forces the next accepted access unit to be a random-access frame.
    public mutating func requireKeyFrame() {
        requiresKeyFrame = true
    }

    private func validateStreamDescriptor() throws {
        try stream.validateForVideoDataChannel()
    }

    private mutating func validateOrdering(of accessUnit: EncodedVideoAccessUnit) throws {
        if let streamTimescale, accessUnit.timescale != streamTimescale {
            throw VideoDataValidationError.timescaleMismatch(
                expected: streamTimescale,
                received: accessUnit.timescale
            )
        }
        if let lastSequence, accessUnit.sequence <= lastSequence {
            throw VideoDataValidationError.sequenceNotIncreasing(
                previous: lastSequence,
                received: accessUnit.sequence
            )
        }
        if let lastSequence,
            lastSequence == UInt64.max || accessUnit.sequence != lastSequence + 1
        {
            // A missing predictive frame makes the rest of that GOP unsafe to decode. Requiring a
            // random-access frame lets a lossy bounded channel recover without preserving corrupt
            // decoder state.
            requiresKeyFrame = true
        }
        if let lastPresentationTimestamp,
            accessUnit.presentationTimestamp <= lastPresentationTimestamp
        {
            throw VideoDataValidationError.presentationTimestampNotIncreasing(
                previous: lastPresentationTimestamp,
                received: accessUnit.presentationTimestamp
            )
        }
    }

    private func validateDecoderReadiness(for accessUnit: EncodedVideoAccessUnit) throws {
        switch accessUnit.codec {
        case .jpeg:
            break
        case .h264, .hevc:
            guard let configuration = currentConfiguration else {
                throw VideoDataValidationError.codecConfigurationRequired
            }
            guard accessUnit.codecConfigurationGeneration == configuration.generation else {
                throw VideoDataValidationError.codecConfigurationGenerationMismatch(
                    expected: configuration.generation,
                    received: accessUnit.codecConfigurationGeneration
                )
            }
            try Self.validateLengthPrefixedAccessUnit(
                accessUnit.payload,
                nalLengthFieldBytes: configuration.nalLengthFieldBytes
            )
            if accessUnit.isKeyFrame {
                try Self.validateRandomAccessNAL(in: accessUnit, configuration: configuration)
            }
        }

        if requiresKeyFrame, !accessUnit.isKeyFrame {
            throw VideoDataValidationError.keyFrameRequired
        }
    }

    private static func validateLengthPrefixedAccessUnit(
        _ payload: Data,
        nalLengthFieldBytes: UInt8
    ) throws {
        let lengthByteCount = Int(nalLengthFieldBytes)
        var offset = payload.startIndex
        var nalCount = 0

        while offset < payload.endIndex {
            guard payload.distance(from: offset, to: payload.endIndex) >= lengthByteCount else {
                throw VideoDataValidationError.invalidLengthPrefixedAccessUnit
            }

            var nalLength = 0
            for _ in 0..<lengthByteCount {
                nalLength = (nalLength << 8) | Int(payload[offset])
                offset = payload.index(after: offset)
            }
            guard nalLength > 0,
                payload.distance(from: offset, to: payload.endIndex) >= nalLength
            else {
                throw VideoDataValidationError.invalidLengthPrefixedAccessUnit
            }

            offset = payload.index(offset, offsetBy: nalLength)
            nalCount += 1
        }

        guard nalCount > 0 else {
            throw VideoDataValidationError.invalidLengthPrefixedAccessUnit
        }
    }

    private static func validateRandomAccessNAL(
        in accessUnit: EncodedVideoAccessUnit,
        configuration: VideoCodecConfiguration
    ) throws {
        let nalUnits = try splitNALUnits(
            accessUnit.payload,
            nalLengthFieldBytes: configuration.nalLengthFieldBytes
        )
        let containsRandomAccessNAL = nalUnits.contains { nalUnit in
            guard let firstByte = nalUnit.first else { return false }
            switch accessUnit.codec {
            case .h264:
                return firstByte & 0x1F == 5
            case .hevc:
                return (16...23).contains((firstByte >> 1) & 0x3F)
            case .jpeg:
                return true
            }
        }
        guard containsRandomAccessNAL else {
            throw VideoDataValidationError.keyFrameFlagDoesNotMatchPayload
        }
    }

    private static func splitNALUnits(
        _ payload: Data,
        nalLengthFieldBytes: UInt8
    ) throws -> [Data] {
        let lengthByteCount = Int(nalLengthFieldBytes)
        var offset = payload.startIndex
        var nalUnits: [Data] = []

        while offset < payload.endIndex {
            guard payload.distance(from: offset, to: payload.endIndex) >= lengthByteCount else {
                throw VideoDataValidationError.invalidLengthPrefixedAccessUnit
            }

            var nalLength = 0
            for _ in 0..<lengthByteCount {
                nalLength = (nalLength << 8) | Int(payload[offset])
                offset = payload.index(after: offset)
            }
            guard nalLength > 0,
                payload.distance(from: offset, to: payload.endIndex) >= nalLength
            else {
                throw VideoDataValidationError.invalidLengthPrefixedAccessUnit
            }

            let end = payload.index(offset, offsetBy: nalLength)
            nalUnits.append(payload.subdata(in: offset..<end))
            offset = end
        }

        return nalUnits
    }
}

public enum VideoDataValidationError: Error, Equatable, LocalizedError, Sendable {
    case invalidLimit(name: String, value: Int, hardMaximum: Int)
    case serializedMessageTooLarge(actualBytes: Int, maximumBytes: Int)
    case unsupportedProtocolVersion(UInt16)
    case unexpectedFields([String])
    case invalidTaggedMessagePayload
    case emptyCodecParameterSet(kind: VideoCodecParameterSetKind)
    case invalidCodecParameterSetCount(Int)
    case codecConfigurationTooLarge(actualBytes: Int, maximumBytes: Int)
    case codecConfigurationNotAllowed(codec: VideoCodec)
    case invalidCodecConfigurationGeneration(UInt32)
    case invalidNALLengthFieldBytes(UInt8)
    case missingRequiredCodecParameterSets(codec: VideoCodec)
    case invalidCodecParameterSet(codec: VideoCodec, kind: VideoCodecParameterSetKind)
    case invalidCaptureTimestamp(Int64)
    case invalidPresentationTimestamp(Int64)
    case invalidDuration(Int64)
    case invalidTimescale(Int32)
    case durationExceedsMaximum(duration: Int64, timescale: Int32)
    case emptyAccessUnit
    case accessUnitTooLarge(actualBytes: Int, maximumBytes: Int)
    case invalidJPEGMetadata
    case invalidJPEGPayload
    case missingCodecConfigurationGeneration
    case invalidStreamDescriptor
    case sessionMismatch(expected: UUID, received: UUID)
    case streamMismatch(expected: VideoSubscriptionID, received: VideoSubscriptionID)
    case codecMismatch(expected: VideoCodec, received: VideoCodec)
    case codecConfigurationGenerationNotIncreasing(previous: UInt32, received: UInt32)
    case codecConfigurationGenerationConflict(UInt32)
    case sequenceNotIncreasing(previous: UInt64, received: UInt64)
    case presentationTimestampNotIncreasing(previous: Int64, received: Int64)
    case timescaleMismatch(expected: Int32, received: Int32)
    case codecConfigurationRequired
    case codecConfigurationGenerationMismatch(expected: UInt32, received: UInt32?)
    case invalidLengthPrefixedAccessUnit
    case keyFrameRequired
    case keyFrameFlagDoesNotMatchPayload

    public var errorDescription: String? {
        switch self {
        case .invalidLimit(let name, let value, let hardMaximum):
            "\(name) must be between 1 and \(hardMaximum); received \(value)."
        case .serializedMessageTooLarge(let actualBytes, let maximumBytes):
            "Serialized video message is \(actualBytes) bytes; maximum is \(maximumBytes)."
        case .unsupportedProtocolVersion(let version):
            "Unsupported video data protocol version \(version)."
        case .unexpectedFields(let fields):
            "Unexpected video message fields: \(fields.joined(separator: ", "))."
        case .invalidTaggedMessagePayload:
            "Video message tag does not match its payload."
        case .emptyCodecParameterSet(let kind):
            "The \(kind.rawValue.uppercased()) parameter set is empty."
        case .invalidCodecParameterSetCount(let count):
            "Codec configuration contains an invalid parameter-set count (\(count))."
        case .codecConfigurationTooLarge(let actualBytes, let maximumBytes):
            "Codec configuration is \(actualBytes) bytes; maximum is \(maximumBytes)."
        case .codecConfigurationNotAllowed(let codec):
            "\(codec.rawValue) does not use an out-of-band codec configuration."
        case .invalidCodecConfigurationGeneration(let generation):
            "Codec configuration generation must be positive; received \(generation)."
        case .invalidNALLengthFieldBytes(let length):
            "NAL length field must be 1, 2, or 4 bytes; received \(length)."
        case .missingRequiredCodecParameterSets(let codec):
            "Codec configuration is missing required \(codec.rawValue) parameter sets."
        case .invalidCodecParameterSet(let codec, let kind):
            "The \(kind.rawValue.uppercased()) NAL header is invalid for \(codec.rawValue)."
        case .invalidCaptureTimestamp(let timestamp):
            "Capture timestamp cannot be negative; received \(timestamp)."
        case .invalidPresentationTimestamp(let timestamp):
            "Presentation timestamp cannot be negative; received \(timestamp)."
        case .invalidDuration(let duration):
            "Access-unit duration must be positive; received \(duration)."
        case .invalidTimescale(let timescale):
            "Access-unit timescale is invalid (\(timescale))."
        case .durationExceedsMaximum(let duration, let timescale):
            "Access-unit duration \(duration)/\(timescale) exceeds 10 seconds."
        case .emptyAccessUnit:
            "Encoded video access unit is empty."
        case .accessUnitTooLarge(let actualBytes, let maximumBytes):
            "Encoded video access unit is \(actualBytes) bytes; maximum is \(maximumBytes)."
        case .invalidJPEGMetadata:
            "Every JPEG access unit must be a key frame without a codec configuration generation."
        case .invalidJPEGPayload:
            "JPEG payload is missing its start or end marker."
        case .missingCodecConfigurationGeneration:
            "H.264 and HEVC access units must identify a codec configuration generation."
        case .invalidStreamDescriptor:
            "Negotiated video dimensions, decoded pixel count, frame rate, or bitrate exceed the data-channel limits."
        case .sessionMismatch(let expected, let received):
            "Video session mismatch; expected \(expected), received \(received)."
        case .streamMismatch(let expected, let received):
            "Video stream mismatch; expected \(expected.rawValue), received \(received.rawValue)."
        case .codecMismatch(let expected, let received):
            "Video codec mismatch; expected \(expected.rawValue), received \(received.rawValue)."
        case .codecConfigurationGenerationNotIncreasing(let previous, let received):
            "Codec configuration generation did not increase (\(previous) to \(received))."
        case .codecConfigurationGenerationConflict(let generation):
            "Codec configuration generation \(generation) was reused with different contents."
        case .sequenceNotIncreasing(let previous, let received):
            "Video sequence did not increase (\(previous) to \(received))."
        case .presentationTimestampNotIncreasing(let previous, let received):
            "Video presentation timestamp did not increase (\(previous) to \(received))."
        case .timescaleMismatch(let expected, let received):
            "Video timescale changed within a stream; expected \(expected), received \(received)."
        case .codecConfigurationRequired:
            "A matching codec configuration is required before compressed frames."
        case .codecConfigurationGenerationMismatch(let expected, let received):
            "Codec configuration generation mismatch; expected \(expected), received \(String(describing: received))."
        case .invalidLengthPrefixedAccessUnit:
            "H.264 or HEVC payload is not a valid length-prefixed access unit."
        case .keyFrameRequired:
            "A key frame is required before delta frames can be decoded."
        case .keyFrameFlagDoesNotMatchPayload:
            "Access unit is marked as a key frame but has no random-access NAL unit."
        }
    }

    /// Whether receiver feedback should request a fresh random-access frame after this failure.
    public var shouldRequestKeyFrame: Bool {
        switch self {
        case .codecConfigurationRequired,
            .codecConfigurationGenerationMismatch,
            .invalidLengthPrefixedAccessUnit,
            .keyFrameRequired,
            .keyFrameFlagDoesNotMatchPayload:
            true
        default:
            false
        }
    }

    /// Whether a receiver may safely discard this message and keep consuming the channel.
    /// These cases are expected around datagram duplication, reordering, or reconnect boundaries;
    /// malformed current-stream media remains fatal or enters key-frame recovery instead.
    public var isDiscardableByReceiver: Bool {
        switch self {
        case .sessionMismatch,
            .streamMismatch,
            .codecMismatch,
            .codecConfigurationGenerationNotIncreasing,
            .sequenceNotIncreasing,
            .presentationTimestampNotIncreasing:
            true
        default:
            false
        }
    }
}

private struct ArbitraryCodingKey: CodingKey {
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

private func rejectUnknownKeys<Key>(
    from decoder: any Decoder,
    allowed: Key.Type
) throws where Key: CodingKey & CaseIterable {
    let container = try decoder.container(keyedBy: ArbitraryCodingKey.self)
    let allowedNames = Set(Key.allCases.map(\.stringValue))
    let unexpected = container.allKeys.map(\.stringValue).filter { !allowedNames.contains($0) }.sorted()
    guard unexpected.isEmpty else {
        throw VideoDataValidationError.unexpectedFields(unexpected)
    }
}
