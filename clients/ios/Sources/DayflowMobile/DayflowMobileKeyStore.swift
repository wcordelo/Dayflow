import Foundation
import Security

public enum DayflowMobileKeyStoreError: Error, Equatable {
    case invalidKey
    case missingAccount
    case keychain(OSStatus)
}

/// Keychain custody for iOS account, wrapping, and request-signing keys.
public final class DayflowMobileKeyStore: @unchecked Sendable {
    private let service = "app.dayflow.mobile.multidevice"

    public init() {}

    public func rootKey(accountID: String) -> Data? {
        load(accountID: accountID, name: "root-key-v1")
    }

    public func accountKeyRing(accountID: String) throws -> DayflowMobileAccountKeyRing? {
        if let encoded = secret(accountID: accountID, name: "account-key-ring-v1") {
            do {
                return try JSONDecoder().decode(DayflowMobileAccountKeyRing.self, from: encoded)
            } catch {
                throw DayflowMobileKeyStoreError.invalidKey
            }
        }
        guard let rootKey = rootKey(accountID: accountID) else { return nil }
        return try DayflowMobileAccountKeyRing(rootKey: rootKey)
    }

    public func storeAccountKeyRing(
        _ value: DayflowMobileAccountKeyRing,
        accountID: String
    ) throws {
        guard value.jsonData.isEmpty == false else {
            throw DayflowMobileKeyStoreError.invalidKey
        }
        try storeSecret(value.jsonData, accountID: accountID, name: "account-key-ring-v1")
        // Keep the v1 alias for older builds and for a controlled migration
        // from clients that have not yet adopted key-ring replay.
        if let rootKey = value.keyData(for: 1) {
            try storeRootKey(rootKey, accountID: accountID)
        }
    }

    /// True after this device has received an explicitly admitted account key.
    /// The marker is only local continuity state; the relay remains the
    /// authority for registration, approval, and wrapped-key delivery.
    public func hasAccountKeyAdmission(accountID: String) -> Bool {
        secret(accountID: accountID, name: "account-key-admitted-v1")?.elementsEqual(Data([UInt8(1)])) == true
    }

    public func markAccountKeyAdmitted(accountID: String) throws {
        try storeSecret(Data([UInt8(1)]), accountID: accountID, name: "account-key-admitted-v1")
    }

    public func pendingAccountKeyRing(accountID: String) throws -> DayflowMobileAccountKeyRing? {
        guard let encoded = secret(accountID: accountID, name: "account-key-ring-pending-v1") else {
            return nil
        }
        do {
            return try JSONDecoder().decode(DayflowMobileAccountKeyRing.self, from: encoded)
        } catch {
            throw DayflowMobileKeyStoreError.invalidKey
        }
    }

    public func storePendingAccountKeyRing(
        _ value: DayflowMobileAccountKeyRing,
        accountID: String
    ) throws {
        guard value.jsonData.isEmpty == false else {
            throw DayflowMobileKeyStoreError.invalidKey
        }
        try storeSecret(value.jsonData, accountID: accountID, name: "account-key-ring-pending-v1")
    }

    public func clearPendingAccountKeyRing(accountID: String) {
        deleteSecret(accountID: accountID, name: "account-key-ring-pending-v1")
    }

    public func storeRootKey(_ value: Data, accountID: String) throws {
        try store(value, accountID: accountID, name: "root-key-v1", length: 32)
    }

    public func deviceKeyMaterial(accountID: String) -> (privateKey: Data, publicKey: Data)? {
        guard let privateKey = load(accountID: accountID, name: "device-private-v1"),
              let publicKey = load(accountID: accountID, name: "device-public-v1"),
              privateKey.count == 32, publicKey.count == 32
        else { return nil }
        return (privateKey, publicKey)
    }

    public func storeDeviceKeyMaterial(
        privateKey: Data,
        publicKey: Data,
        accountID: String
    ) throws {
        try store(privateKey, accountID: accountID, name: "device-private-v1", length: 32)
        try store(publicKey, accountID: accountID, name: "device-public-v1", length: 32)
    }

    public func signingKeyMaterial(accountID: String) -> (privateKey: Data, publicKey: Data)? {
        guard let privateKey = load(accountID: accountID, name: "signing-private-v1"),
              let publicKey = load(accountID: accountID, name: "signing-public-v1"),
              privateKey.count == 32, publicKey.count == 32
        else { return nil }
        return (privateKey, publicKey)
    }

    public func storeSigningKeyMaterial(
        privateKey: Data,
        publicKey: Data,
        accountID: String
    ) throws {
        try store(privateKey, accountID: accountID, name: "signing-private-v1", length: 32)
        try store(publicKey, accountID: accountID, name: "signing-public-v1", length: 32)
    }

    public func secret(accountID: String, name: String) -> Data? {
        load(accountID: accountID, name: name)
    }

    public func storeSecret(_ value: Data, accountID: String, name: String) throws {
        try store(value, accountID: accountID, name: name, length: nil)
    }

    public func deleteSecret(accountID: String, name: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount(accountID: accountID, name: name),
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    private func keychainAccount(accountID: String, name: String) -> String {
        "\(name):\(accountID)"
    }

    private func load(accountID: String, name: String) -> Data? {
        guard accountID.isEmpty == false else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount(accountID: accountID, name: name),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func store(_ value: Data, accountID: String, name: String, length: Int?) throws {
        guard accountID.isEmpty == false else {
            throw DayflowMobileKeyStoreError.missingAccount
        }
        if let length, value.count != length {
            throw DayflowMobileKeyStoreError.invalidKey
        }
        let account = keychainAccount(accountID: accountID, name: name)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: value] as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw DayflowMobileKeyStoreError.keychain(status) }
        var add = query
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw DayflowMobileKeyStoreError.keychain(addStatus)
        }
        if addStatus == errSecDuplicateItem {
            try store(value, accountID: accountID, name: name, length: length)
        }
    }
}
