import CryptoKit
import Foundation
import Security

struct ROBVideoAuthenticationChallenge: Sendable {
    static let encodedSize = 65

    let channelID: Data
    let serverNonce: Data
    let robotID: UUID

    var encoded: Data {
        var data = Data([ROBCerebroVideoProtocol.protocolVersion])
        data.append(channelID)
        data.append(serverNonce)
        data.append(robotID.robVideoBytes)
        return data
    }

    init(_ input: Data) throws {
        let data = Data(input)
        guard data.count == Self.encodedSize,
            data[0] == ROBCerebroVideoProtocol.protocolVersion,
            let robotID = UUID(robVideoBytes: Data(data[49..<65]))
        else {
            throw ROBCerebroTransportError.authenticationFailed
        }
        channelID = Data(data[1..<17])
        serverNonce = Data(data[17..<49])
        self.robotID = robotID
    }
}

struct ROBVideoAuthenticationProof: Sendable {
    static let encodedSize = 97

    let channelID: Data
    let controllerID: UUID
    let clientNonce: Data
    let mac: Data

    var encoded: Data {
        var data = Data([ROBCerebroVideoProtocol.protocolVersion])
        data.append(channelID)
        data.append(controllerID.robVideoBytes)
        data.append(clientNonce)
        data.append(mac)
        return data
    }
}

struct ROBVideoAuthenticationAccepted: Sendable {
    static let encodedSize = 65

    let channelID: Data
    let controllerID: UUID
    let mac: Data

    init(_ input: Data) throws {
        let data = Data(input)
        guard data.count == Self.encodedSize,
            data[0] == ROBCerebroVideoProtocol.protocolVersion,
            let controllerID = UUID(robVideoBytes: Data(data[17..<33]))
        else {
            throw ROBCerebroTransportError.authenticationFailed
        }
        channelID = Data(data[1..<17])
        self.controllerID = controllerID
        mac = Data(data[33..<65])
    }
}

enum ROBVideoAuthenticator {
    private static let transcriptDomain = Data("robvideo/1\0".utf8)
    private static let clientDomain = Data("ROBVIDEO-AUTH-V1/CLIENT-PROOF\0".utf8)
    private static let serverDomain = Data("ROBVIDEO-AUTH-V1/SERVER-ACCEPTED\0".utf8)

    static func makeProof(
        challenge: ROBVideoAuthenticationChallenge,
        credential: ROBCerebroCredential
    ) throws -> ROBVideoAuthenticationProof {
        guard challenge.robotID == credential.robotID,
            credential.sharedSecret.count == 32
        else {
            throw ROBCerebroTransportError.authenticationFailed
        }
        let nonce = try secureRandomData(count: 32)
        let transcript = makeTranscript(
            challenge: challenge,
            controllerID: credential.controllerID,
            clientNonce: nonce
        )
        var input = clientDomain
        input.append(transcript)
        return ROBVideoAuthenticationProof(
            channelID: challenge.channelID,
            controllerID: credential.controllerID,
            clientNonce: nonce,
            mac: Data(
                HMAC<SHA256>.authenticationCode(
                    for: input,
                    using: SymmetricKey(data: credential.sharedSecret)
                ))
        )
    }

    static func validate(
        _ accepted: ROBVideoAuthenticationAccepted,
        proof: ROBVideoAuthenticationProof,
        challenge: ROBVideoAuthenticationChallenge,
        credential: ROBCerebroCredential
    ) -> Bool {
        guard accepted.channelID == challenge.channelID,
            accepted.controllerID == credential.controllerID,
            proof.channelID == challenge.channelID,
            proof.controllerID == credential.controllerID,
            proof.mac.count == SHA256.byteCount,
            accepted.mac.count == SHA256.byteCount
        else {
            return false
        }
        var input = serverDomain
        input.append(
            makeTranscript(
                challenge: challenge,
                controllerID: proof.controllerID,
                clientNonce: proof.clientNonce
            ))
        input.append(proof.mac)
        return HMAC<SHA256>.isValidAuthenticationCode(
            accepted.mac,
            authenticating: input,
            using: SymmetricKey(data: credential.sharedSecret)
        )
    }

    private static func makeTranscript(
        challenge: ROBVideoAuthenticationChallenge,
        controllerID: UUID,
        clientNonce: Data
    ) -> Data {
        var data = transcriptDomain
        data.append(challenge.encoded)
        data.append(controllerID.robVideoBytes)
        data.append(clientNonce)
        return data
    }

    private static func secureRandomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw ROBCerebroTransportError.authenticationFailed
        }
        return data
    }
}
