import Foundation
import CryptoKit
import Security

enum DayflowMultiDeviceKeyStoreError: LocalizedError, Equatable {
  case randomGenerationFailed(OSStatus)
  case keychainWriteFailed(OSStatus)
  case keychainReadFailed(OSStatus)
  case invalidKey
  case missingAccount

  var errorDescription: String? {
    switch self {
    case .randomGenerationFailed(let status):
      return "macOS could not generate an encryption key (status \(status))."
    case .keychainWriteFailed(let status):
      return "macOS could not store the encryption key (status \(status))."
    case .keychainReadFailed(let status):
      return "macOS could not read the encryption key (status \(status))."
    case .invalidKey:
      return "The stored Dayflow encryption key is invalid."
    case .missingAccount:
      return "Sign in to Dayflow before creating account encryption keys."
    }
  }
}

/// Keychain-only storage for account material owned by the Mac client.
///
/// This deliberately does not reuse the API-key helper: that helper has a
/// string-oriented interface and diagnostic logging, neither of which is
/// appropriate for account root keys.
final class DayflowMultiDeviceKeyStore {
  static let shared = DayflowMultiDeviceKeyStore()

  private let service = "com.teleportlabs.dayflow.multidevice"
  private let accountRootKeyAccount = "account-root-key-v1"
  private let accountKeyRingAccount = "account-key-ring-v1"
  private let accountKeyAdmissionAccount = "account-key-admitted-v1"
  private let pendingAccountKeyRingAccount = "account-key-ring-pending-v1"
  private let devicePrivateKeyAccount = "device-private-key-v1"
  private let devicePublicKeyAccount = "device-public-key-v1"
  private let deviceSigningPrivateKeyAccount = "device-signing-private-key-v1"
  private let deviceSigningPublicKeyAccount = "device-signing-public-key-v1"
  private let queue = DispatchQueue(label: "com.teleportlabs.dayflow.multidevice.keys", qos: .userInitiated)

  private init() {}

  var hasAccountRootKey: Bool {
    loadAccountKeyRing() != nil
  }

  /// Records that this device has obtained an account key through an explicit
  /// relay bootstrap, approved-device wrapper, or recovery-kit restore. The
  /// marker is only a local continuity record; the relay remains authoritative
  /// for registration, approval, and wrapped-key delivery.
  var hasAccountKeyAdmission: Bool {
    guard let account = scopedAccount(accountKeyAdmissionAccount) else { return false }
    return load(account: account)?.elementsEqual(Data([UInt8(1)])) == true
  }

  func markAccountKeyAdmitted() throws {
    guard let account = scopedAccount(accountKeyAdmissionAccount) else {
      throw DayflowMultiDeviceKeyStoreError.missingAccount
    }
    try queue.sync {
      try upsert(Data([UInt8(1)]), account: account)
    }
  }

  func loadAccountRootKey() -> Data? {
    queue.sync {
      guard let account = scopedAccount(accountRootKeyAccount),
        let data = try? read(account: account), data.count == 32
      else {
        return nil
      }
      return data
    }
  }

  func loadAccountKeyRing() -> DayflowAccountKeyRing? {
    guard let accountID = DayflowAccountIdentity.currentID else { return nil }
    return loadKeyRing(accountID: accountID, allowLegacyRootKey: true)
  }

  func loadLocalWorkspaceKeyRing() -> DayflowAccountKeyRing? {
    loadKeyRing(accountID: DayflowMultiDeviceAccountScope.localWorkspaceID)
  }

  @discardableResult
  func ensureLocalWorkspaceKeyRing() throws -> DayflowAccountKeyRing {
    if let existing = loadLocalWorkspaceKeyRing() {
      return existing
    }

    let ring = try DayflowAccountKeyRing(rootKey: DayflowCoreBridge.shared.generateAccountRootKey())
    try storeLocalWorkspaceKeyRing(ring)
    return ring
  }

  func storeAccountKeyRing(_ ring: DayflowAccountKeyRing) throws {
    guard ring.keyData(for: ring.activeKeyVersion) != nil else {
      throw DayflowMultiDeviceKeyStoreError.invalidKey
    }
    guard let accountID = DayflowAccountIdentity.currentID,
      let account = scopedAccount(accountKeyRingAccount, accountID: accountID)
    else {
      throw DayflowMultiDeviceKeyStoreError.missingAccount
    }
    try storeKeyRing(ring, account: account, rootAccountID: accountID)
  }

  func storeLocalWorkspaceKeyRing(_ ring: DayflowAccountKeyRing) throws {
    guard ring.keyData(for: ring.activeKeyVersion) != nil,
      let account = scopedAccount(
        accountKeyRingAccount,
        accountID: DayflowMultiDeviceAccountScope.localWorkspaceID
      )
    else {
      throw DayflowMultiDeviceKeyStoreError.invalidKey
    }
    try storeKeyRing(ring, account: account, rootAccountID: nil)
  }

  private func loadKeyRing(accountID: String, allowLegacyRootKey: Bool = false) -> DayflowAccountKeyRing? {
    guard let account = scopedAccount(accountKeyRingAccount, accountID: accountID) else { return nil }
    if let data = load(account: account),
      let ring = try? JSONDecoder().decode(DayflowAccountKeyRing.self, from: data),
      ring.keyData(for: ring.activeKeyVersion) != nil
    {
      return ring
    }
    guard allowLegacyRootKey,
      accountID == DayflowAccountIdentity.currentID,
      let rootKey = loadAccountRootKey(),
      let ring = try? DayflowAccountKeyRing(rootKey: rootKey)
    else {
      return nil
    }
    return ring
  }

  private func storeKeyRing(
    _ ring: DayflowAccountKeyRing,
    account: String,
    rootAccountID: String?
  ) throws {
    try queue.sync {
      try upsert(ring.jsonData, account: account)
      if let rootKey = ring.keyData(for: 1),
        let rootAccount = scopedAccount(accountRootKeyAccount, accountID: rootAccountID)
      {
        try upsert(rootKey, account: rootAccount)
      }
    }
  }

  func loadPendingAccountKeyRing() -> DayflowAccountKeyRing? {
    guard let account = scopedAccount(pendingAccountKeyRingAccount),
      let data = load(account: account),
      let ring = try? JSONDecoder().decode(DayflowAccountKeyRing.self, from: data),
      ring.keyData(for: ring.activeKeyVersion) != nil
    else {
      return nil
    }
    return ring
  }

  func storePendingAccountKeyRing(_ ring: DayflowAccountKeyRing) throws {
    guard ring.keyData(for: ring.activeKeyVersion) != nil,
      let account = scopedAccount(pendingAccountKeyRingAccount)
    else {
      throw DayflowMultiDeviceKeyStoreError.invalidKey
    }
    try queue.sync {
      try upsert(ring.jsonData, account: account)
    }
  }

  func clearPendingAccountKeyRing() {
    guard let account = scopedAccount(pendingAccountKeyRingAccount) else { return }
    queue.sync {
      _ = SecItemDelete(query(account: account, returningData: false) as CFDictionary)
    }
  }

  func createAccountRootKeyIfNeeded() throws -> Data {
    try queue.sync {
      guard let account = scopedAccount(accountRootKeyAccount) else {
        throw DayflowMultiDeviceKeyStoreError.missingAccount
      }
      if let existing = try? read(account: account), existing.count == 32 {
        return existing
      }

      let key = try DayflowCoreBridge.shared.generateAccountRootKey()

      do {
        try write(key, account: account)
      } catch DayflowMultiDeviceKeyStoreError.keychainWriteFailed(let status)
        where status == errSecDuplicateItem
      {
        // Another process created it between the read and write. Read the
        // canonical stored value rather than returning an unpersisted key.
        guard let existing = try? read(account: account), existing.count == 32 else {
          throw DayflowMultiDeviceKeyStoreError.invalidKey
        }
        return existing
      }
      return key
    }
  }

  func storeAccountRootKey(_ key: Data) throws {
    guard key.count == 32 else {
      throw DayflowMultiDeviceKeyStoreError.invalidKey
    }
    try queue.sync {
      guard let account = scopedAccount(accountRootKeyAccount) else {
        throw DayflowMultiDeviceKeyStoreError.missingAccount
      }
      let query = query(account: account, returningData: false)
      let updateStatus = SecItemUpdate(
        query as CFDictionary,
        [kSecValueData as String: key] as CFDictionary
      )
      if updateStatus == errSecSuccess {
        return
      }
      guard updateStatus == errSecItemNotFound else {
        throw DayflowMultiDeviceKeyStoreError.keychainWriteFailed(updateStatus)
      }
      try write(key, account: account)
    }
  }

  func loadDevicePrivateKey() -> Data? {
    guard let account = scopedAccount(devicePrivateKeyAccount) else { return nil }
    return load(account: account)
  }

  func loadDevicePublicKey() -> Data? {
    guard let account = scopedAccount(devicePublicKeyAccount) else { return nil }
    return load(account: account)
  }

  func loadDeviceSigningPrivateKey() -> Data? {
    guard let account = scopedAccount(deviceSigningPrivateKeyAccount) else { return nil }
    return load(account: account)
  }

  func loadDeviceSigningPublicKey() -> Data? {
    guard let account = scopedAccount(deviceSigningPublicKeyAccount) else { return nil }
    return load(account: account)
  }

  func storeDeviceKeyMaterial(privateKey: Data, publicKey: Data) throws {
    guard privateKey.count == 32, publicKey.count == 32 else {
      throw DayflowMultiDeviceKeyStoreError.invalidKey
    }
    guard let privateAccount = scopedAccount(devicePrivateKeyAccount),
      let publicAccount = scopedAccount(devicePublicKeyAccount)
    else {
      throw DayflowMultiDeviceKeyStoreError.missingAccount
    }
    try queue.sync {
      try upsert(privateKey, account: privateAccount)
      try upsert(publicKey, account: publicAccount)
    }
  }

  func storeDeviceSigningKeyMaterial(privateKey: Data, publicKey: Data) throws {
    guard privateKey.count == 32, publicKey.count == 32 else {
      throw DayflowMultiDeviceKeyStoreError.invalidKey
    }
    guard let privateAccount = scopedAccount(deviceSigningPrivateKeyAccount),
      let publicAccount = scopedAccount(deviceSigningPublicKeyAccount)
    else {
      throw DayflowMultiDeviceKeyStoreError.missingAccount
    }
    try queue.sync {
      try upsert(privateKey, account: privateAccount)
      try upsert(publicKey, account: publicAccount)
    }
  }

  private func scopedAccount(_ base: String) -> String? {
    scopedAccount(base, accountID: DayflowAccountIdentity.currentID)
  }

  private func scopedAccount(_ base: String, accountID: String?) -> String? {
    guard let accountID, accountID.isEmpty == false else {
      return nil
    }
    let digest = SHA256.hash(data: Data(accountID.utf8))
    let suffix = digest.map { String(format: "%02x", $0) }.joined()
    return base + ":" + suffix
  }

  private func query(account: String, returningData: Bool) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if returningData {
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
    }
    return query
  }

  private func read(account: String) throws -> Data {
    var result: AnyObject?
    let status = SecItemCopyMatching(query(account: account, returningData: true) as CFDictionary, &result)
    guard status == errSecSuccess else {
      throw DayflowMultiDeviceKeyStoreError.keychainReadFailed(status)
    }
    guard let data = result as? Data else {
      throw DayflowMultiDeviceKeyStoreError.invalidKey
    }
    return data
  }

  private func load(account: String) -> Data? {
    queue.sync {
      try? read(account: account)
    }
  }

  private func write(_ data: Data, account: String) throws {
    var addQuery = query(account: account, returningData: false)
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw DayflowMultiDeviceKeyStoreError.keychainWriteFailed(addStatus)
    }
  }

  private func upsert(_ data: Data, account: String) throws {
    let query = query(account: account, returningData: false)
    let updateStatus = SecItemUpdate(
      query as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw DayflowMultiDeviceKeyStoreError.keychainWriteFailed(updateStatus)
    }
    try write(data, account: account)
  }
}
