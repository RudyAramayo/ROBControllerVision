import CryptoKit
import Foundation
import Network
import Security

enum ROBControlWireMessageType: UInt32, Sendable {
    case invalid = 0
    case sendData = 1
    case setAutomationScript = 2
    case pairingChallenge = 3
    case pairingProof = 4
    case pairingAccepted = 5
    case pairingRejected = 6
    case lidarTelemetry = 7
}

struct ROBControlAuthChallenge: Equatable, Sendable {
    static let encodedSize = 65

    let sessionID: Data
    let serverNonce: Data
    let robotID: UUID

    init?(sessionID: Data, serverNonce: Data, robotID: UUID) {
        guard sessionID.count == 16, serverNonce.count == 32 else { return nil }
        self.sessionID = sessionID
        self.serverNonce = serverNonce
        self.robotID = robotID
    }

    init?(_ data: Data) {
        guard data.count == Self.encodedSize,
            data[data.startIndex] == 1,
            let robotID = UUID(robControlBytes: data.subdata(in: 49..<65))
        else {
            return nil
        }
        sessionID = data.subdata(in: 1..<17)
        serverNonce = data.subdata(in: 17..<49)
        self.robotID = robotID
    }

    var encoded: Data {
        var data = Data([1])
        data.append(sessionID)
        data.append(serverNonce)
        data.append(robotID.robControlBytes)
        return data
    }

    var sessionUUID: UUID? {
        UUID(robControlBytes: sessionID)
    }
}

struct ROBControlAuthProof: Equatable, Sendable {
    static let encodedSize = 97

    let sessionID: Data
    let controllerID: UUID
    let clientNonce: Data
    let mac: Data

    init?(sessionID: Data, controllerID: UUID, clientNonce: Data, mac: Data) {
        guard sessionID.count == 16, clientNonce.count == 32, mac.count == 32 else { return nil }
        self.sessionID = sessionID
        self.controllerID = controllerID
        self.clientNonce = clientNonce
        self.mac = mac
    }

    init?(_ data: Data) {
        guard data.count == Self.encodedSize,
            data[data.startIndex] == 1,
            let controllerID = UUID(robControlBytes: data.subdata(in: 17..<33))
        else {
            return nil
        }
        sessionID = data.subdata(in: 1..<17)
        self.controllerID = controllerID
        clientNonce = data.subdata(in: 33..<65)
        mac = data.subdata(in: 65..<97)
    }

    var encoded: Data {
        var data = Data([1])
        data.append(sessionID)
        data.append(controllerID.robControlBytes)
        data.append(clientNonce)
        data.append(mac)
        return data
    }
}

struct ROBControlAuthAccepted: Equatable, Sendable {
    static let encodedSize = 65

    let sessionID: Data
    let controllerID: UUID
    let mac: Data

    init?(sessionID: Data, controllerID: UUID, mac: Data) {
        guard sessionID.count == 16, mac.count == 32 else { return nil }
        self.sessionID = sessionID
        self.controllerID = controllerID
        self.mac = mac
    }

    init?(_ data: Data) {
        guard data.count == Self.encodedSize,
            data[data.startIndex] == 1,
            let controllerID = UUID(robControlBytes: data.subdata(in: 17..<33))
        else {
            return nil
        }
        sessionID = data.subdata(in: 1..<17)
        self.controllerID = controllerID
        mac = data.subdata(in: 33..<65)
    }

    var encoded: Data {
        var data = Data([1])
        data.append(sessionID)
        data.append(controllerID.robControlBytes)
        data.append(mac)
        return data
    }
}

enum ROBControlAuthenticator {
    private static let transcriptDomain = Data("robctl/2\0".utf8)
    private static let clientDomain = Data("ROBCTL-AUTH-V1/CLIENT-PROOF\0".utf8)
    private static let serverDomain = Data("ROBCTL-AUTH-V1/SERVER-ACCEPTED\0".utf8)

    static func makeProof(
        challenge: ROBControlAuthChallenge,
        credential: ROBCerebroCredential
    ) throws -> ROBControlAuthProof {
        try makeProof(
            challenge: challenge,
            credential: credential,
            clientNonce: secureRandomData(count: 32)
        )
    }

    /// Deterministic injection point for cross-repository golden-vector tests.
    static func makeProof(
        challenge: ROBControlAuthChallenge,
        credential: ROBCerebroCredential,
        clientNonce: Data
    ) throws -> ROBControlAuthProof {
        guard credential.isValid, clientNonce.count == 32 else {
            throw ROBCerebroTransportError.authenticationFailed
        }
        let transcript = makeTranscript(
            challenge: challenge,
            controllerID: credential.controllerID,
            clientNonce: clientNonce
        )
        guard
            let proof = ROBControlAuthProof(
                sessionID: challenge.sessionID,
                controllerID: credential.controllerID,
                clientNonce: clientNonce,
                mac: hmac(domain: clientDomain, transcript: transcript, secret: credential.sharedSecret)
            )
        else {
            throw ROBCerebroTransportError.authenticationFailed
        }
        return proof
    }

    static func validate(
        _ proof: ROBControlAuthProof,
        challenge: ROBControlAuthChallenge,
        credential: ROBCerebroCredential
    ) -> Bool {
        guard credential.isValid,
            proof.sessionID == challenge.sessionID,
            proof.controllerID == credential.controllerID,
            challenge.robotID == credential.robotID
        else {
            return false
        }
        var input = clientDomain
        input.append(
            makeTranscript(
                challenge: challenge,
                controllerID: proof.controllerID,
                clientNonce: proof.clientNonce
            )
        )
        return HMAC<SHA256>.isValidAuthenticationCode(
            proof.mac,
            authenticating: input,
            using: SymmetricKey(data: credential.sharedSecret)
        )
    }

    static func accepted(
        for proof: ROBControlAuthProof,
        challenge: ROBControlAuthChallenge,
        credential: ROBCerebroCredential
    ) throws -> ROBControlAuthAccepted {
        guard validate(proof, challenge: challenge, credential: credential) else {
            throw ROBCerebroTransportError.authenticationFailed
        }
        let transcript = makeTranscript(
            challenge: challenge,
            controllerID: proof.controllerID,
            clientNonce: proof.clientNonce
        )
        var input = serverDomain
        input.append(transcript)
        input.append(proof.mac)
        let mac = Data(
            HMAC<SHA256>.authenticationCode(
                for: input,
                using: SymmetricKey(data: credential.sharedSecret)
            )
        )
        guard
            let accepted = ROBControlAuthAccepted(
                sessionID: proof.sessionID,
                controllerID: proof.controllerID,
                mac: mac
            )
        else {
            throw ROBCerebroTransportError.authenticationFailed
        }
        return accepted
    }

    static func validate(
        _ accepted: ROBControlAuthAccepted,
        proof: ROBControlAuthProof,
        challenge: ROBControlAuthChallenge,
        credential: ROBCerebroCredential
    ) -> Bool {
        guard credential.isValid,
            accepted.sessionID == challenge.sessionID,
            accepted.controllerID == credential.controllerID
        else {
            return false
        }
        var input = serverDomain
        input.append(
            makeTranscript(
                challenge: challenge,
                controllerID: proof.controllerID,
                clientNonce: proof.clientNonce
            )
        )
        input.append(proof.mac)
        return HMAC<SHA256>.isValidAuthenticationCode(
            accepted.mac,
            authenticating: input,
            using: SymmetricKey(data: credential.sharedSecret)
        )
    }

    private static func makeTranscript(
        challenge: ROBControlAuthChallenge,
        controllerID: UUID,
        clientNonce: Data
    ) -> Data {
        var data = transcriptDomain
        data.append(challenge.encoded)
        data.append(controllerID.robControlBytes)
        data.append(clientNonce)
        return data
    }

    private static func hmac(domain: Data, transcript: Data, secret: Data) -> Data {
        var input = domain
        input.append(transcript)
        return Data(
            HMAC<SHA256>.authenticationCode(
                for: input,
                using: SymmetricKey(data: secret)
            )
        )
    }

    private static func secureRandomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw ROBCerebroTransportError.authenticationFailed
        }
        return data
    }
}

struct ROBControlFrameHeader: Equatable, Sendable {
    static let magic: UInt32 = 0x5243_544C  // "RCTL"
    static let version: UInt8 = 2
    static let encodedSize = 40
    static let maximumPayloadLength = 4 * 1_024 * 1_024

    let type: ROBControlWireMessageType
    let payloadLength: UInt32
    let sequence: UInt64
    let messageID: UUID

    init(
        type: ROBControlWireMessageType,
        payloadLength: UInt32,
        sequence: UInt64,
        messageID: UUID = UUID()
    ) {
        self.type = type
        self.payloadLength = payloadLength
        self.sequence = sequence
        self.messageID = messageID
    }

    init?(_ data: Data) {
        guard data.count == Self.encodedSize,
            data.readUInt32(at: 0) == Self.magic,
            data[data.startIndex + 4] == Self.version,
            Int(data[data.startIndex + 5]) == Self.encodedSize,
            data.readUInt16(at: 8) == 0,
            data.readUInt16(at: 10) == 0,
            let rawType = data.readUInt16(at: 6),
            let type = ROBControlWireMessageType(rawValue: UInt32(rawType)),
            type != .invalid,
            let payloadLength = data.readUInt32(at: 12),
            payloadLength <= UInt32(Self.maximumPayloadLength),
            let sequence = data.readUInt64(at: 16),
            let messageID = UUID(robControlBytes: data.subdata(in: 24..<40))
        else {
            return nil
        }
        self.type = type
        self.payloadLength = payloadLength
        self.sequence = sequence
        self.messageID = messageID
    }

    var encoded: Data {
        var data = Data(capacity: Self.encodedSize)
        data.appendBigEndian(Self.magic)
        data.append(Self.version)
        data.append(UInt8(Self.encodedSize))
        data.appendBigEndian(UInt16(type.rawValue))
        data.appendBigEndian(UInt16(0))  // flags
        data.appendBigEndian(UInt16(0))  // channel
        data.appendBigEndian(payloadLength)
        data.appendBigEndian(sequence)
        data.append(messageID.robControlBytes)
        return data
    }
}

final class ROBControlV2Framer: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: ROBControlV2Framer.self)
    static var label: String { "ROBControlV2" }

    private var nextOutputSequence: UInt64 = 1
    private var lastInputSequence: UInt64 = 0

    required init(framer _: NWProtocolFramer.Instance) {}

    func start(framer _: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer _: NWProtocolFramer.Instance) {}
    func stop(framer _: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer _: NWProtocolFramer.Instance) {}

    func handleOutput(
        framer: NWProtocolFramer.Instance,
        message: NWProtocolFramer.Message,
        messageLength: Int,
        isComplete _: Bool
    ) {
        guard messageLength >= 0,
            messageLength <= ROBControlFrameHeader.maximumPayloadLength,
            message.robControlMessageType != .invalid,
            nextOutputSequence != UInt64.max
        else {
            framer.markFailed(error: NWError.posix(.EMSGSIZE))
            return
        }

        let header = ROBControlFrameHeader(
            type: message.robControlMessageType,
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
            var parsedHeader: ROBControlFrameHeader?
            var malformed = false
            let headerSize = ROBControlFrameHeader.encodedSize
            let parsed = framer.parseInput(
                minimumIncompleteLength: headerSize,
                maximumLength: headerSize
            ) { buffer, _ in
                guard let buffer, buffer.count >= headerSize else { return 0 }
                parsedHeader = ROBControlFrameHeader(Data(buffer.prefix(headerSize)))
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
            message.robControlMessageType = header.type
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

extension NWProtocolFramer.Message {
    var robControlMessageType: ROBControlWireMessageType {
        get { self["ROBControlMessageType"] as? ROBControlWireMessageType ?? .invalid }
        set { self["ROBControlMessageType"] = newValue }
    }
}

extension UUID {
    var robControlBytes: Data {
        var value = uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    init?(robControlBytes data: Data) {
        guard data.count == 16 else { return nil }
        var value: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0) }
        self.init(uuid: value)
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBigEndian(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    func readUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return (UInt16(self[startIndex + offset]) << 8)
            | UInt16(self[startIndex + offset + 1])
    }

    func readUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return (UInt32(self[startIndex + offset]) << 24)
            | (UInt32(self[startIndex + offset + 1]) << 16)
            | (UInt32(self[startIndex + offset + 2]) << 8)
            | UInt32(self[startIndex + offset + 3])
    }

    func readUInt64(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        var value: UInt64 = 0
        for index in offset..<(offset + 8) {
            value = (value << 8) | UInt64(self[startIndex + index])
        }
        return value
    }
}
