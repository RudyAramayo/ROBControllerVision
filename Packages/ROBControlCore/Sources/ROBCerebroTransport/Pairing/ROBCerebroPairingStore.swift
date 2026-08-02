import Foundation
import Network
import Security

public enum ROBCerebroPairingStatus: Equatable, Sendable {
    case notPaired
    case paired(ROBCerebroCredential)
}

/// Keychain-backed storage for the credential issued by Cerebro.
///
/// This client store deliberately has no server-identity creation API. It persists only the exact
/// credential carried by a `ROBCTL2:` enrollment code, including Cerebro's canonical certificate pin.
public struct ROBCerebroPairingStore: Sendable {
    public static let pairingCodePrefix = "ROBCTL2:"
    public static let controlServiceType = "_robctl._udp"
    public static let controlApplicationProtocol = "robctl/2"

    private static let maximumPairingPayloadBytes = 4_096
    private static let defaultKeychainService = "com.orbitusrobotics.robctl.v2"
    private static let defaultKeychainAccount = "paired-cerebro-profile"

    private let keychainService: String
    private let keychainAccount: String

    public init() {
        keychainService = Self.defaultKeychainService
        keychainAccount = Self.defaultKeychainAccount
    }

    init(keychainService: String, keychainAccount: String) {
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
    }

    /// Decodes and validates a pairing code without persisting it.
    public static func credential(fromPairingCode code: String) throws -> ROBCerebroCredential {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            trimmed.range(
                of: pairingCodePrefix,
                options: [.anchored, .caseInsensitive]
            ) != nil
        else {
            throw ROBCerebroTransportError.invalidPairingCode
        }

        let encodedPayload = trimmed.dropFirst(pairingCodePrefix.count)
        let normalized = String(encodedPayload.filter { !$0.isWhitespace })
        guard let payload = Data(base64Encoded: normalized),
            !payload.isEmpty,
            payload.count <= maximumPairingPayloadBytes,
            let credential = try? JSONDecoder().decode(ROBCerebroCredential.self, from: payload),
            credential.isValid
        else {
            throw ROBCerebroTransportError.invalidPairingCode
        }
        return credential
    }

    /// Installs a code transferred out-of-band from Cerebro. Replacing a code intentionally
    /// replaces this device's previous pairing.
    @discardableResult
    public func install(pairingCode: String) throws -> ROBCerebroCredential {
        let credential = try Self.credential(fromPairingCode: pairingCode)
        guard credential.effectiveRole == .operatorController else {
            throw ROBCerebroTransportError.authorizationFailed
        }
        try store(credential)
        return credential
    }

    public func loadCredential() throws -> ROBCerebroCredential? {
        guard let data = try loadData() else { return nil }
        guard let credential = try? JSONDecoder().decode(ROBCerebroCredential.self, from: data),
            credential.isValid
        else {
            throw ROBCerebroTransportError.invalidPairingCode
        }
        return credential
    }

    public func status() throws -> ROBCerebroPairingStatus {
        if let credential = try loadCredential() {
            return .paired(credential)
        }
        return .notPaired
    }

    public func removeCredential() throws {
        let status = SecItemDelete(genericQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ROBCerebroTransportError.keychain(status)
        }
    }

    /// Reads Cerebro's routing-only `robot_id` TXT key. Authentication still requires the
    /// certificate pin and pairing proof; Bonjour metadata is never trusted as identity proof.
    public static func robotID(fromBonjourMetadata metadata: NWBrowser.Result.Metadata) -> UUID? {
        guard case .bonjour(let txtRecord) = metadata,
            let value = txtRecord["robot_id"]
        else {
            return nil
        }
        return UUID(uuidString: value)
    }

    public static func result(
        _ result: NWBrowser.Result,
        matches credential: ROBCerebroCredential
    ) -> Bool {
        guard case .bonjour(let txtRecord) = result.metadata else { return false }
        return robotID(fromBonjourMetadata: result.metadata) == credential.robotID
            && txtRecord["ver"] == "2"
            && txtRecord["alpn"] == controlApplicationProtocol
    }

    private var genericQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private func loadData() throws -> Data? {
        var query = genericQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ROBCerebroTransportError.keychain(status)
        }
        return data
    }

    private func store(_ credential: ROBCerebroCredential) throws {
        guard credential.isValid else {
            throw ROBCerebroTransportError.invalidPairingCode
        }
        let data = try JSONEncoder().encode(credential)

        let updateStatus = SecItemUpdate(
            genericQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw ROBCerebroTransportError.keychain(updateStatus)
        }

        var addQuery = genericQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                genericQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard retryStatus == errSecSuccess else {
                throw ROBCerebroTransportError.keychain(retryStatus)
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw ROBCerebroTransportError.keychain(addStatus)
        }
    }
}
