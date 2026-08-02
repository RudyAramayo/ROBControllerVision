import Foundation

public enum ROBCerebroTransportError: Error, Equatable, LocalizedError, Sendable {
    case pairingRequired
    case invalidPairingCode
    case keychain(Int32)
    case unsupportedService(String)
    case discoveryFailed(String)
    case connectionFailed(String)
    case authenticationFailed
    case authorizationFailed
    case timedOut
    case cancelled
    case invalidWireMessage
    case invalidApplicationPayload
    case videoUnavailable
    case protocolMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .pairingRequired:
            "Pair this Vision Pro with Cerebro before connecting."
        case .invalidPairingCode:
            "The Cerebro pairing code is invalid or incomplete."
        case .keychain(let status):
            "Unable to access the Cerebro credential in Keychain (OSStatus \(status))."
        case .unsupportedService(let service):
            "Unsupported Cerebro Bonjour service: \(service)"
        case .discoveryFailed(let detail):
            "Cerebro discovery failed: \(detail)"
        case .connectionFailed(let detail):
            "The Cerebro connection failed: \(detail)"
        case .authenticationFailed:
            "Cerebro rejected the certificate pin or pairing proof. Re-pair this device if Cerebro's identity was deliberately replaced."
        case .authorizationFailed:
            "This paired device is not authorized for the requested operation."
        case .timedOut:
            "The Cerebro operation timed out."
        case .cancelled:
            "The Cerebro operation was cancelled."
        case .invalidWireMessage:
            "Cerebro sent an invalid or unsupported wire message."
        case .invalidApplicationPayload:
            "The controller application payload was invalid or oversized."
        case .videoUnavailable:
            "Cerebro's video service is unavailable."
        case .protocolMismatch(let detail):
            "Cerebro protocol mismatch: \(detail)"
        }
    }
}
