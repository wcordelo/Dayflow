import Foundation
import CryptoKit

/// Wire-compatible with `dayflow_core::EventEnvelope`.
///
/// `nonce` and `ciphertext` are base64 strings. Encryption/decryption belongs
/// to the shared core bridge, while the local persistence boundary still
/// validates their opaque wire shape before storing them.
struct DayflowEventEnvelope: Codable, Equatable, Hashable, Sendable, Identifiable {
  static let currentSchemaVersion: UInt16 = 1
  static let maxLogicalClock: UInt64 = 9_007_199_254_740_991

  let eventID: String
  let deviceID: String
  let logicalClock: UInt64
  let schemaVersion: UInt16
  let keyVersion: UInt32
  let nonce: String
  let ciphertext: String

  var id: String { eventID }

  enum CodingKeys: String, CodingKey {
    case eventID = "event_id"
    case deviceID = "device_id"
    case logicalClock = "logical_clock"
    case schemaVersion = "schema_version"
    case keyVersion = "key_version"
    case nonce
    case ciphertext
  }
}

enum DayflowWireEnvelopeValidation {
  private static let eventNonceBytes = 24
  private static let eventAuthTagBytes = 16

  static func hasValidEncryptedFieldShape(nonce: String, ciphertext: String) -> Bool {
    guard let nonceData = decode(nonce), let ciphertextData = decode(ciphertext) else {
      return false
    }
    return nonceData.count == eventNonceBytes && ciphertextData.count >= eventAuthTagBytes
  }

  static func decode(_ value: String) -> Data? {
    guard value.isEmpty == false else { return nil }
    guard value.unicodeScalars.allSatisfy({ scalar in
      switch scalar.value {
      case 43, 45, 47, 48...57, 61, 65...90, 95, 97...122:
        return true
      default:
        return false
      }
    }) else {
      return nil
    }

    let normalized = value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let unpadded: String
    if let paddingIndex = normalized.firstIndex(of: "=") {
      guard normalized.count.isMultiple(of: 4),
        normalized[paddingIndex...].allSatisfy({ $0 == "=" }),
        normalized.distance(from: paddingIndex, to: normalized.endIndex) <= 2
      else { return nil }
      unpadded = String(normalized[..<paddingIndex])
    } else {
      unpadded = normalized
    }
    guard unpadded.utf8.count % 4 != 1 else { return nil }
    let padding = String(repeating: "=", count: (4 - unpadded.utf8.count % 4) % 4)
    return Data(base64Encoded: unpadded + padding)
  }
}

/// Native secure-store representation of all account encryption keys retained
/// for local replay. The JSON shape intentionally matches the Rust C/UniFFI
/// key-ring contract; key bytes remain inside the platform secure store or the
/// synchronous Rust call and never enter an event envelope.
struct DayflowAccountKeyRing: Codable, Equatable, Sendable {
  let activeKeyVersion: UInt32
  let keys: [String: String]

  init(activeKeyVersion: UInt32, keyData: [UInt32: Data]) throws {
    guard activeKeyVersion > 0,
      keyData.isEmpty == false,
      keyData[activeKeyVersion]?.count == 32,
      keyData.keys.allSatisfy({ $0 > 0 })
    else {
      throw DayflowMultiDeviceKeyStoreError.invalidKey
    }

    self.activeKeyVersion = activeKeyVersion
    self.keys = keyData.reduce(into: [:]) { result, entry in
      result[String(entry.key)] = entry.value.base64EncodedString()
    }
  }

  init(rootKey: Data) throws {
    try self.init(activeKeyVersion: 1, keyData: [1: rootKey])
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let activeKeyVersion = try container.decode(UInt32.self, forKey: .activeKeyVersion)
    let keys = try container.decode([String: String].self, forKey: .keys)
    guard let activeEncoded = keys[String(activeKeyVersion)],
      let activeData = Data(base64Encoded: activeEncoded)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .keys,
        in: container,
        debugDescription: "Dayflow account key ring is missing its active key"
      )
    }
    guard activeKeyVersion > 0,
      keys.isEmpty == false,
      keys.keys.allSatisfy({ (UInt32($0) ?? 0) > 0 }),
      activeData.count == 32,
      keys.values.allSatisfy({ Data(base64Encoded: $0)?.count == 32 })
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .keys,
        in: container,
        debugDescription: "Dayflow account key ring contains invalid key material"
      )
    }
    self.activeKeyVersion = activeKeyVersion
    self.keys = keys
  }

  private enum CodingKeys: String, CodingKey {
    case activeKeyVersion = "active_key_version"
    case keys
  }

  var jsonData: Data {
    // This initializer has already validated the key-ring shape. Encoding is
    // deterministic because the Rust parser treats the map as a BTreeMap.
    (try? JSONEncoder().encode(self)) ?? Data()
  }

  func keyData(for version: UInt32) -> Data? {
    guard let encoded = keys[String(version)],
      let data = Data(base64Encoded: encoded),
      data.count == 32
    else {
      return nil
    }
    return data
  }

  func adding(_ key: Data, version: UInt32, active: Bool = false) throws -> DayflowAccountKeyRing {
    var keyData = keys.reduce(into: [UInt32: Data]()) { result, entry in
      guard let version = UInt32(entry.key), let data = Data(base64Encoded: entry.value) else { return }
      result[version] = data
    }
    keyData[version] = key
    return try DayflowAccountKeyRing(
      activeKeyVersion: active ? version : activeKeyVersion,
      keyData: keyData
    )
  }

  func withActiveVersion(_ version: UInt32) throws -> DayflowAccountKeyRing {
    let keyData = keys.reduce(into: [UInt32: Data]()) { result, entry in
      guard let version = UInt32(entry.key), let data = Data(base64Encoded: entry.value) else { return }
      result[version] = data
    }
    guard keyData[version] != nil else { throw DayflowMultiDeviceKeyStoreError.invalidKey }
    return try DayflowAccountKeyRing(activeKeyVersion: version, keyData: keyData)
  }
}

enum DayflowSyncEventState: String, Codable, Sendable {
  case pending
  case acknowledged
}

enum DayflowSyncState: String, Codable, Equatable, Sendable {
  case unknown
  case synced
  case waitingForApproval = "waiting_for_approval"
  case failed
}

struct DayflowSyncStatus: Equatable, Sendable {
  let pendingCount: Int
  let lastAcknowledgedAt: Date?
  let lastSyncAt: Date?
  let lastSuccessfulSyncAt: Date?
  let lastSyncState: DayflowSyncState
  /// A bounded, non-user-content failure category. Never persist the raw
  /// server or provider error in the local sync metadata table.
  let lastFailureCode: String?
  let sharedCoreContractVersion: String

  static let initial = DayflowSyncStatus(
    pendingCount: 0,
    lastAcknowledgedAt: nil,
    lastSyncAt: nil,
    lastSuccessfulSyncAt: nil,
    lastSyncState: .unknown,
    lastFailureCode: nil,
    sharedCoreContractVersion: "0.1"
  )
}

enum DayflowDeviceIdentity {
  private static let deviceIDKey = "dayflowMultiDeviceID"

  static var currentID: String {
    if let saved = UserDefaults.standard.string(forKey: deviceIDKey), saved.isEmpty == false {
      return saved
    }

    let generated = UUID().uuidString.lowercased()
    UserDefaults.standard.set(generated, forKey: deviceIDKey)
    return generated
  }
}

/// The account identity is deliberately separate from the device identity.
/// Device-local event IDs remain stable, while secure-store records and relay
/// cursors cannot accidentally be reused after a different Dayflow account
/// signs in on the same Mac.
enum DayflowAccountIdentity {
  private static let accountIDKey = "dayflowMultiDeviceAccountID"

  static var currentID: String? {
    guard let value = UserDefaults.standard.string(forKey: accountIDKey), value.isEmpty == false else {
      return nil
    }
    return value
  }

  static func setCurrentID(_ value: String) {
    guard value.isEmpty == false else { return }
    UserDefaults.standard.set(value, forKey: accountIDKey)
  }

  static func clear() {
    UserDefaults.standard.removeObject(forKey: accountIDKey)
  }
}

/// The legacy Mac database predates account-scoped storage. Until the read
/// model itself is split into per-account databases, bind it to the first
/// authenticated account and refuse to migrate those rows into another
/// account. This prevents a sign-out/sign-in transition from leaking local
/// history into the wrong encrypted event stream.
enum DayflowLocalDataAccountBinding {
  private static let accountIDKey = "dayflowLocalDataAccountBinding"

  static var boundAccountID: String? {
    UserDefaults.standard.string(forKey: accountIDKey)
  }

  static func bindIfNeeded(to accountID: String) throws {
    let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.isEmpty == false else { throw DayflowMigrationError.missingAccount }
    if let boundAccountID, boundAccountID != normalized {
      throw DayflowMigrationError.localDataBoundToAnotherAccount
    }
    UserDefaults.standard.set(normalized, forKey: accountIDKey)
  }
}

/// Stable, non-reversible account scope used for local multi-device records.
///
/// The account ID itself must not be copied into filenames or database keys:
/// besides being unnecessary, it would make a local database backup disclose
/// the account identifier. The scope is only an addressing token; the account
/// root key still protects event contents.
enum DayflowMultiDeviceAccountScope {
  static let localWorkspaceID = "local-workspace-v1"

  static var current: String? {
    token(for: DayflowAccountIdentity.currentID)
  }

  static var localWorkspace: String {
    // This is a stable local token, not an account identifier. Keep the same
    // hashed database scope shape as account records so the storage layer has
    // one isolation rule for both signed-out and signed-in workspaces.
    token(for: localWorkspaceID)!
  }

  static func token(for accountID: String?) -> String? {
    guard let accountID, accountID.isEmpty == false else { return nil }
    let digest = SHA256.hash(data: Data(accountID.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
