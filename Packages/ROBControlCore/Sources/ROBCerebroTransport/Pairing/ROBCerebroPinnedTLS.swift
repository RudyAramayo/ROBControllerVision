import CryptoKit
import Foundation
import Network
import Security

/// Client-only QUIC/TLS construction. This type never loads or creates a local server identity.
enum ROBCerebroPinnedTLS {
    private static let verificationQueue = DispatchQueue(
        label: "com.orbitusrobotics.robctl.v2.vision.verify"
    )

    static func makeControlClientParameters(
        credential: ROBCerebroCredential
    ) throws -> NWParameters {
        guard credential.isValid else {
            throw ROBCerebroTransportError.invalidPairingCode
        }

        let quic = NWProtocolQUIC.Options(
            alpn: [ROBCerebroPairingStore.controlApplicationProtocol]
        )
        quic.direction = .bidirectional
        quic.idleTimeout = 10_000

        let securityOptions = quic.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv13)
        installExactLeafPin(
            credential.certificateSHA256,
            on: securityOptions
        )

        let parameters = NWParameters(quic: quic)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        parameters.serviceClass = .signaling
        parameters.defaultProtocolStack.applicationProtocols.insert(
            NWProtocolFramer.Options(definition: ROBControlV2Framer.definition),
            at: 0
        )
        return parameters
    }

    static func installExactLeafPin(
        _ expectedFingerprint: Data,
        on securityOptions: sec_protocol_options_t
    ) {
        precondition(expectedFingerprint.count == 32)
        sec_protocol_options_set_verify_block(
            securityOptions,
            { _, trust, complete in
                let trustReference = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(trustReference) as? [SecCertificate],
                    let leaf = chain.first
                else {
                    complete(false)
                    return
                }
                let leafData = SecCertificateCopyData(leaf) as Data
                let actualFingerprint = Data(SHA256.hash(data: leafData))
                complete(actualFingerprint == expectedFingerprint)
            },
            verificationQueue
        )
    }
}
