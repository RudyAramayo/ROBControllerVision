import Foundation
@preconcurrency import Network

/// Network.framework framer for Cerebro's ordered `RVID` v1 QUIC stream.
final class ROBVideoFramer: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: ROBVideoFramer.self)
    static var label: String { "ROBVideoV1" }

    private var nextOutputSequence: UInt64 = 1
    private var lastInputSequence: UInt64 = 0

    required init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    func handleOutput(
        framer: NWProtocolFramer.Instance,
        message: NWProtocolFramer.Message,
        messageLength: Int,
        isComplete: Bool
    ) {
        guard messageLength >= 0,
            messageLength <= ROBCerebroVideoProtocol.maximumFramedPayloadBytes,
            message.robVideoMessageType != .invalid,
            nextOutputSequence < UInt64.max
        else {
            framer.markFailed(error: NWError.posix(.EMSGSIZE))
            return
        }

        let header = ROBVideoFrameHeader(
            type: message.robVideoMessageType,
            payloadLength: UInt32(messageLength),
            sequence: nextOutputSequence
        )
        nextOutputSequence += 1
        framer.writeOutput(data: header.encoded)
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            framer.markFailed(error: NWError.posix(.EIO))
        }
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var parsedHeader: ROBVideoFrameHeader?
            var malformed = false
            let headerSize = ROBVideoFrameHeader.encodedSize
            let parsed = framer.parseInput(
                minimumIncompleteLength: headerSize,
                maximumLength: headerSize
            ) { buffer, _ in
                guard let buffer, buffer.count >= headerSize else { return 0 }
                parsedHeader = ROBVideoFrameHeader(buffer)
                malformed = parsedHeader == nil
                return headerSize
            }
            guard parsed else { return headerSize }
            guard !malformed,
                let header = parsedHeader,
                header.sequence > lastInputSequence
            else {
                framer.markFailed(error: NWError.posix(.EPROTO))
                return 0
            }
            lastInputSequence = header.sequence

            let message = NWProtocolFramer.Message(definition: Self.definition)
            message.robVideoMessageType = header.type
            if !framer.deliverInputNoCopy(
                length: Int(header.payloadLength),
                message: message,
                isComplete: true
            ) {
                return 0
            }
        }
    }
}

private struct ROBVideoFrameHeader {
    static let magic: UInt32 = 0x5256_4944  // RVID
    static let encodedSize = 32

    let type: ROBVideoMessageType
    let payloadLength: UInt32
    let sequence: UInt64

    init(type: ROBVideoMessageType, payloadLength: UInt32, sequence: UInt64) {
        self.type = type
        self.payloadLength = payloadLength
        self.sequence = sequence
    }

    init?(_ buffer: UnsafeMutableRawBufferPointer) {
        guard buffer.count >= Self.encodedSize,
            Self.readUInt32(buffer, at: 0) == Self.magic,
            buffer[4] == ROBCerebroVideoProtocol.protocolVersion,
            buffer[5] == UInt8(Self.encodedSize),
            let type = ROBVideoMessageType(rawValue: Self.readUInt16(buffer, at: 6)),
            type != .invalid,
            Self.readUInt16(buffer, at: 12) == 0,
            Self.readUInt16(buffer, at: 14) == 0,
            Self.readUInt64(buffer, at: 24) == 0
        else {
            return nil
        }
        let payloadLength = Self.readUInt32(buffer, at: 8)
        let limit =
            type.isMedia
            ? ROBCerebroVideoProtocol.maximumFramedPayloadBytes
            : ROBCerebroVideoProtocol.maximumControlMessageBytes
        guard payloadLength <= UInt32(limit) else { return nil }

        self.type = type
        self.payloadLength = payloadLength
        sequence = Self.readUInt64(buffer, at: 16)
    }

    var encoded: Data {
        var data = Data()
        data.reserveCapacity(Self.encodedSize)
        data.appendUInt32BigEndian(Self.magic)
        data.append(ROBCerebroVideoProtocol.protocolVersion)
        data.append(UInt8(Self.encodedSize))
        data.appendUInt16BigEndian(type.rawValue)
        data.appendUInt32BigEndian(payloadLength)
        data.appendUInt16BigEndian(0)
        data.appendUInt16BigEndian(0)
        data.appendUInt64BigEndian(sequence)
        data.appendUInt64BigEndian(0)
        return data
    }

    private static func readUInt16(
        _ buffer: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> UInt16 {
        (UInt16(buffer[offset]) << 8) | UInt16(buffer[offset + 1])
    }

    private static func readUInt32(
        _ buffer: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> UInt32 {
        var value: UInt32 = 0
        for index in offset..<(offset + 4) {
            value = (value << 8) | UInt32(buffer[index])
        }
        return value
    }

    private static func readUInt64(
        _ buffer: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> UInt64 {
        var value: UInt64 = 0
        for index in offset..<(offset + 8) {
            value = (value << 8) | UInt64(buffer[index])
        }
        return value
    }
}

extension NWProtocolFramer.Message {
    var robVideoMessageType: ROBVideoMessageType {
        get { self["ROBVideoMessageType"] as? ROBVideoMessageType ?? .invalid }
        set { self["ROBVideoMessageType"] = newValue }
    }
}
