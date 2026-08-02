import Foundation

/// The server-owned role encoded into a Cerebro-issued `ROBCTL2:` credential.
///
/// Older controller credentials did not include a role. They remain compatible and are interpreted
/// as operator credentials; Cerebro's own paired-device registry remains authoritative.
public enum ROBCerebroPeerRole: String, Codable, CaseIterable, Sendable {
    case operatorController
    case lidarPublisher
}

/// Pairing material issued by Cerebro for one controller device.
///
/// A Vision Pro must receive its own credential. Copying another controller's credential would clone
/// that controller identity and conflict with Cerebro's duplicate-session and revocation behavior.
public struct ROBCerebroCredential: Codable, Equatable, Sendable {
    public let version: Int
    public let robotID: UUID
    public let controllerID: UUID
    public let serviceType: String
    public let applicationProtocol: String
    public let certificateSHA256: Data
    public let sharedSecret: Data
    public let role: ROBCerebroPeerRole?
    public let deviceName: String?
    public let issuedAtMilliseconds: UInt64?

    public init(
        version: Int,
        robotID: UUID,
        controllerID: UUID,
        serviceType: String,
        applicationProtocol: String,
        certificateSHA256: Data,
        sharedSecret: Data,
        role: ROBCerebroPeerRole? = nil,
        deviceName: String? = nil,
        issuedAtMilliseconds: UInt64? = nil
    ) {
        self.version = version
        self.robotID = robotID
        self.controllerID = controllerID
        self.serviceType = serviceType
        self.applicationProtocol = applicationProtocol
        self.certificateSHA256 = certificateSHA256
        self.sharedSecret = sharedSecret
        self.role = role
        self.deviceName = deviceName
        self.issuedAtMilliseconds = issuedAtMilliseconds
    }

    public var isValid: Bool {
        let normalizedName = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return version == 2
            && serviceType == ROBCerebroPairingStore.controlServiceType
            && applicationProtocol == ROBCerebroPairingStore.controlApplicationProtocol
            && certificateSHA256.count == 32
            && sharedSecret.count == 32
            && (normalizedName == nil
                || (normalizedName!.count >= 1
                    && normalizedName!.count <= 80
                    && normalizedName!.rangeOfCharacter(from: .controlCharacters) == nil))
            && (issuedAtMilliseconds == nil || issuedAtMilliseconds! > 0)
    }

    /// Compatibility interpretation for credentials issued before device roles were added.
    public var effectiveRole: ROBCerebroPeerRole {
        role ?? .operatorController
    }
}
