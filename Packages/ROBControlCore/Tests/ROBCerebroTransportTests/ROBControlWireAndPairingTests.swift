import Foundation
import Testing

@testable import ROBCerebroTransport

@Suite("Cerebro control pairing and wire compatibility")
struct ROBControlWireAndPairingTests {
    @Test("Legacy and current Cerebro credentials decode through the same model")
    func credentialCompatibility() throws {
        let base: [String: Any] = [
            "version": 2,
            "robotID": "00112233-4455-6677-8899-AABBCCDDEEFF",
            "controllerID": "10213243-5465-7687-98A9-BACBDCEDFE0F",
            "serviceType": "_robctl._udp",
            "applicationProtocol": "robctl/2",
            "certificateSHA256": Data(repeating: 0x11, count: 32).base64EncodedString(),
            "sharedSecret": Data(repeating: 0x22, count: 32).base64EncodedString(),
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: base, options: [.sortedKeys])
        let legacy = try JSONDecoder().decode(ROBCerebroCredential.self, from: legacyData)
        #expect(legacy.isValid)
        #expect(legacy.role == nil)
        #expect(legacy.effectiveRole == .operatorController)

        var current = base
        current["role"] = "operatorController"
        current["deviceName"] = "Apple Vision Pro"
        current["issuedAtMilliseconds"] = 1_785_552_000_000
        let currentData = try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(ROBCerebroCredential.self, from: currentData)
        #expect(decoded.isValid)
        #expect(decoded.role == .operatorController)
        #expect(decoded.deviceName == "Apple Vision Pro")
    }

    @Test("ROBCTL2 decoder preserves the issued credential and rejects another service")
    func pairingCodeDecoding() throws {
        let credential = fixtureCredential()
        let payload = try JSONEncoder().encode(credential)
        let decoded = try ROBCerebroPairingStore.credential(
            fromPairingCode: "robctl2: \(payload.base64EncodedString())"
        )
        #expect(decoded == credential)

        let wrappedPayload = payload.base64EncodedString(options: [.lineLength64Characters])
        let wrapped = try ROBCerebroPairingStore.credential(
            fromPairingCode: "ROBCTL2:\n\(wrappedPayload)"
        )
        #expect(wrapped == credential)

        let wrongService = ROBCerebroCredential(
            version: credential.version,
            robotID: credential.robotID,
            controllerID: credential.controllerID,
            serviceType: "_robvideo._udp",
            applicationProtocol: credential.applicationProtocol,
            certificateSHA256: credential.certificateSHA256,
            sharedSecret: credential.sharedSecret,
            role: credential.role,
            deviceName: credential.deviceName,
            issuedAtMilliseconds: credential.issuedAtMilliseconds
        )
        let wrongCode = "ROBCTL2:" + (try JSONEncoder().encode(wrongService)).base64EncodedString()
        #expect(throws: ROBCerebroTransportError.invalidPairingCode) {
            _ = try ROBCerebroPairingStore.credential(fromPairingCode: wrongCode)
        }
    }

    @Test("RCTL v2 header matches Cerebro's network-byte-order layout")
    func controlHeaderGoldenVector() throws {
        let messageID = try #require(
            UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")
        )
        let header = ROBControlFrameHeader(
            type: .sendData,
            payloadLength: 0x0012_0304,
            sequence: 0x0102_0304_0506_0708,
            messageID: messageID
        )
        let expected = try Data(
            hex:
                "5243544c0228000100000000001203040102030405060708"
                + "00112233445566778899aabbccddeeff"
        )
        #expect(header.encoded == expected)
        #expect(ROBControlFrameHeader(expected) == header)
    }

    @Test("Control challenge/proof/acceptance HMAC matches Cerebro")
    func controlAuthenticationGoldenVector() throws {
        let credential = fixtureCredential()
        let challenge = try #require(
            ROBControlAuthChallenge(
                sessionID: Data(0x00...0x0F),
                serverNonce: Data(0x20...0x3F),
                robotID: credential.robotID
            )
        )
        let proof = try ROBControlAuthenticator.makeProof(
            challenge: challenge,
            credential: credential,
            clientNonce: Data(0x40...0x5F)
        )
        #expect(
            proof.mac
                == (try Data(
                    hex: "8fcefac43d621fae9779f17fb99b89bb03dbd6dd1384928b73e1b8271c5ee208"
                ))
        )
        #expect(ROBControlAuthenticator.validate(proof, challenge: challenge, credential: credential))

        let accepted = try ROBControlAuthenticator.accepted(
            for: proof,
            challenge: challenge,
            credential: credential
        )
        #expect(
            accepted.mac
                == (try Data(
                    hex: "aeb75e58597f74828d0f593ee81d304589491c1e41b29c71c95a0d72199a6696"
                ))
        )
        #expect(
            ROBControlAuthenticator.validate(
                accepted,
                proof: proof,
                challenge: challenge,
                credential: credential
            )
        )
        #expect(challenge.sessionUUID?.robControlBytes == challenge.sessionID)
    }

    private func fixtureCredential() -> ROBCerebroCredential {
        ROBCerebroCredential(
            version: 2,
            robotID: UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!,
            controllerID: UUID(uuidString: "10213243-5465-7687-98a9-bacbdcedfe0f")!,
            serviceType: "_robctl._udp",
            applicationProtocol: "robctl/2",
            certificateSHA256: Data(repeating: 0x55, count: 32),
            sharedSecret: Data(0xA0...0xBF),
            role: .operatorController,
            deviceName: "Apple Vision Pro",
            issuedAtMilliseconds: 1
        )
    }
}

extension Data {
    fileprivate init(hex: String) throws {
        guard hex.count.isMultiple(of: 2) else {
            throw ROBCerebroTransportError.invalidWireMessage
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw ROBCerebroTransportError.invalidWireMessage
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
