import Foundation
#if canImport(DayflowCoreBindings)
import DayflowCoreBindings

private func dayflowRustSignRequest(message: String, privateKey: Data) throws -> Data {
    try signRequest(message: message, privateKey: privateKey)
}

private func dayflowRustCanonicalDeviceRequest(
    method: String,
    pathWithQuery: String,
    body: Data,
    timestamp: Int64,
    nonce: String,
    deviceID: String
) throws -> String {
    try canonicalDeviceRequest(
        method: method,
        pathWithQuery: pathWithQuery,
        body: body,
        timestamp: timestamp,
        nonce: nonce,
        deviceId: deviceID
    )
}

private func dayflowRustCaptureAllowed(
    permissionGranted: Bool,
    userPaused: Bool,
    deviceLocked: Bool,
    sleeping: Bool,
    privateContext: Bool,
    drmContent: Bool
) -> Bool {
    captureAllowed(
        permissionGranted: permissionGranted,
        userPaused: userPaused,
        deviceLocked: deviceLocked,
        sleeping: sleeping,
        privateContext: privateContext,
        drmContent: drmContent
    )
}

private func dayflowRustGenerateAccountRootKey() -> Data {
    generateAccountRootKey()
}

private func dayflowRustRestoreRecoveryKey(kitJSON: String, passphrase: String) throws -> Data {
    try restoreRecoveryKey(kitJson: kitJSON, passphrase: passphrase)
}
#endif

public protocol DayflowCoreBridge: Sendable {
  func project(envelopes: [DayflowEventEnvelope], accountRootKey: Data) throws -> String
  func project(
    envelopes: [DayflowEventEnvelope],
    keyRing: DayflowMobileAccountKeyRing
  ) throws -> String
  func rekey(
    envelopes: [DayflowEventEnvelope],
    sourceKeyRing: DayflowMobileAccountKeyRing,
    destinationKeyRing: DayflowMobileAccountKeyRing
  ) throws -> [DayflowEventEnvelope]
  func generateAccountRootKey() throws -> Data
  func exportRecoveryKit(accountRootKey: Data, passphrase: String) throws -> Data
  func exportRecoveryKit(keyRing: DayflowMobileAccountKeyRing, passphrase: String) throws -> Data
  func restoreRecoveryKey(kit: Data, passphrase: String) throws -> Data
  func restoreRecoveryKeyRing(kit: Data, passphrase: String) throws -> DayflowMobileAccountKeyRing
  func seal(
    payload: Data,
    eventID: String,
    deviceID: String,
    logicalClock: UInt64,
    accountRootKey: Data
  ) throws -> DayflowEventEnvelope
  func seal(
    payload: Data,
    eventID: String,
    deviceID: String,
    logicalClock: UInt64,
    keyVersion: UInt32,
    accountRootKey: Data
  ) throws -> DayflowEventEnvelope
  func generateDeviceKeyMaterial() throws -> (privateKey: Data, publicKey: Data)
  func wrapAccountKey(
    accountRootKey: Data,
    recipientDeviceID: String,
    recipientPublicKey: Data
  ) throws -> Data
  func wrapAccountKey(
    accountRootKey: Data,
    keyVersion: UInt32,
    recipientDeviceID: String,
    recipientPublicKey: Data
  ) throws -> Data
  func unwrapAccountKey(wrappedKey: Data, privateKey: Data) throws -> Data
  func generateDeviceSigningKeyMaterial() throws -> (privateKey: Data, publicKey: Data)
  func canonicalDeviceRequest(
    method: String,
    pathWithQuery: String,
    body: Data,
    timestamp: Int64,
    nonce: String,
    deviceID: String
  ) throws -> String
  func signRequest(message: String, privateKey: Data) throws -> Data
  func logicalDayKey(
    timestampUnix: Int64,
    timezoneOffsetMinutes: Int32,
    boundaryHour: UInt8
  ) throws -> String
  func captureAllowed(
    permissionGranted: Bool,
    userPaused: Bool,
    deviceLocked: Bool,
    sleeping: Bool,
    privateContext: Bool,
    drmContent: Bool
  ) -> Bool
  func captureDecision(contextJSON: String, policyJSON: String) throws -> DayflowCaptureDecision
}

public struct DayflowCaptureDecision: Codable, Equatable, Sendable {
  public let allowed: Bool
  public let reason: String

  public init(allowed: Bool, reason: String) {
    self.allowed = allowed
    self.reason = reason
  }
}

public enum DayflowCoreBridgeError: Error, Equatable {
    case unavailable
    case invalidRootKey
}

/// `clients/generated/swift/DayflowCore.swift` is generated from the Rust
/// component. The packaged XCFramework will conform to this protocol once it
/// is linked into the iOS target. Keeping the client behind a protocol lets
/// timeline and journal UI remain testable without silently replacing
/// encryption with a Swift implementation.
public struct UnavailableDayflowCoreBridge: DayflowCoreBridge {
    public init() {}

  public func project(envelopes: [DayflowEventEnvelope], accountRootKey: Data) throws -> String {
        guard accountRootKey.count == 32 else {
            throw DayflowCoreBridgeError.invalidRootKey
        }
    throw DayflowCoreBridgeError.unavailable
  }

  public func project(
    envelopes: [DayflowEventEnvelope],
    keyRing: DayflowMobileAccountKeyRing
  ) throws -> String {
    throw DayflowCoreBridgeError.unavailable
  }

  public func rekey(
    envelopes: [DayflowEventEnvelope],
    sourceKeyRing: DayflowMobileAccountKeyRing,
    destinationKeyRing: DayflowMobileAccountKeyRing
  ) throws -> [DayflowEventEnvelope] {
    throw DayflowCoreBridgeError.unavailable
  }

  public func generateAccountRootKey() throws -> Data {
    throw DayflowCoreBridgeError.unavailable
  }

  public func exportRecoveryKit(accountRootKey: Data, passphrase: String) throws -> Data {
    throw DayflowCoreBridgeError.unavailable
  }

  public func exportRecoveryKit(keyRing: DayflowMobileAccountKeyRing, passphrase: String) throws -> Data {
    throw DayflowCoreBridgeError.unavailable
  }

  public func restoreRecoveryKey(kit: Data, passphrase: String) throws -> Data {
    throw DayflowCoreBridgeError.unavailable
  }

  public func restoreRecoveryKeyRing(kit: Data, passphrase: String) throws -> DayflowMobileAccountKeyRing {
    throw DayflowCoreBridgeError.unavailable
  }

  public func generateDeviceSigningKeyMaterial() throws -> (privateKey: Data, publicKey: Data) {
    throw DayflowCoreBridgeError.unavailable
  }

  public func seal(
    payload: Data,
    eventID: String,
    deviceID: String,
    logicalClock: UInt64,
    accountRootKey: Data
  ) throws -> DayflowEventEnvelope {
    throw DayflowCoreBridgeError.unavailable
  }

  public func seal(
    payload: Data,
    eventID: String,
    deviceID: String,
    logicalClock: UInt64,
    keyVersion: UInt32,
    accountRootKey: Data
  ) throws -> DayflowEventEnvelope {
    throw DayflowCoreBridgeError.unavailable
  }

  public func generateDeviceKeyMaterial() throws -> (privateKey: Data, publicKey: Data) {
    throw DayflowCoreBridgeError.unavailable
  }

  public func wrapAccountKey(
    accountRootKey: Data,
    recipientDeviceID: String,
    recipientPublicKey: Data
  ) throws -> Data {
    throw DayflowCoreBridgeError.unavailable
  }

  public func wrapAccountKey(
    accountRootKey: Data,
    keyVersion: UInt32,
    recipientDeviceID: String,
    recipientPublicKey: Data
  ) throws -> Data {
    throw DayflowCoreBridgeError.unavailable
  }

  public func unwrapAccountKey(wrappedKey: Data, privateKey: Data) throws -> Data {
    throw DayflowCoreBridgeError.unavailable
  }

  public func signRequest(message: String, privateKey: Data) throws -> Data {
    throw DayflowCoreBridgeError.unavailable
  }

  public func canonicalDeviceRequest(
    method: String,
    pathWithQuery: String,
    body: Data,
    timestamp: Int64,
    nonce: String,
    deviceID: String
  ) throws -> String {
    throw DayflowCoreBridgeError.unavailable
  }

  public func logicalDayKey(
    timestampUnix: Int64,
    timezoneOffsetMinutes: Int32,
    boundaryHour: UInt8
  ) throws -> String {
    throw DayflowCoreBridgeError.unavailable
  }

  public func captureAllowed(
    permissionGranted: Bool,
    userPaused: Bool,
    deviceLocked: Bool,
    sleeping: Bool,
    privateContext: Bool,
    drmContent: Bool
  ) -> Bool { false }

  public func captureDecision(contextJSON: String, policyJSON: String) throws -> DayflowCaptureDecision {
    throw DayflowCoreBridgeError.unavailable
  }
}

#if canImport(DayflowCoreBindings)
/// The production iOS bridge generated from the shared Rust UniFFI contract.
public struct UniFFIDayflowCoreBridge: DayflowCoreBridge {
    public init() {}

    public func project(envelopes: [DayflowEventEnvelope], accountRootKey: Data) throws -> String {
        guard accountRootKey.count == 32 else {
            throw DayflowCoreBridgeError.invalidRootKey
        }
        let envelopeData = try JSONEncoder().encode(envelopes)
        guard let envelopesJSON = String(data: envelopeData, encoding: .utf8) else {
            throw DayflowCoreBridgeError.unavailable
        }
        do {
            return try projectJson(envelopesJson: envelopesJSON, accountRootKey: accountRootKey)
        } catch {
            throw DayflowCoreBridgeError.unavailable
        }
    }

    public func project(
        envelopes: [DayflowEventEnvelope],
        keyRing: DayflowMobileAccountKeyRing
    ) throws -> String {
        let envelopeData = try JSONEncoder().encode(envelopes)
        guard let envelopesJSON = String(data: envelopeData, encoding: .utf8),
              let keyRingJSON = String(data: keyRing.jsonData, encoding: .utf8)
        else { throw DayflowCoreBridgeError.unavailable }
        do {
            return try projectKeyringJson(envelopesJson: envelopesJSON, keyRingJson: keyRingJSON)
        } catch {
            throw DayflowCoreBridgeError.unavailable
        }
    }

    public func rekey(
        envelopes: [DayflowEventEnvelope],
        sourceKeyRing: DayflowMobileAccountKeyRing,
        destinationKeyRing: DayflowMobileAccountKeyRing
    ) throws -> [DayflowEventEnvelope] {
        let envelopeData = try JSONEncoder().encode(envelopes)
        guard let envelopesJSON = String(data: envelopeData, encoding: .utf8),
              let sourceJSON = String(data: sourceKeyRing.jsonData, encoding: .utf8),
              let destinationJSON = String(data: destinationKeyRing.jsonData, encoding: .utf8)
        else { throw DayflowCoreBridgeError.unavailable }
        do {
            let value = try rekeyEnvelopesJson(
                envelopesJson: envelopesJSON,
                sourceKeyRingJson: sourceJSON,
                destinationKeyRingJson: destinationJSON
            )
            guard let data = value.data(using: .utf8) else {
                throw DayflowCoreBridgeError.unavailable
            }
            return try JSONDecoder().decode([DayflowEventEnvelope].self, from: data)
        } catch let error as DayflowCoreBridgeError {
            throw error
        } catch {
            throw DayflowCoreBridgeError.unavailable
        }
    }

    public func generateAccountRootKey() throws -> Data {
        let key = dayflowRustGenerateAccountRootKey()
        guard key.count == 32 else { throw DayflowCoreBridgeError.unavailable }
        return key
    }

    public func exportRecoveryKit(accountRootKey: Data, passphrase: String) throws -> Data {
        guard accountRootKey.count == 32, passphrase.isEmpty == false else {
            throw DayflowCoreBridgeError.invalidRootKey
        }
        let kit = try exportRecoveryKitJson(accountRootKey: accountRootKey, passphrase: passphrase)
        guard let data = kit.data(using: .utf8) else { throw DayflowCoreBridgeError.unavailable }
        return data
    }

    public func exportRecoveryKit(keyRing: DayflowMobileAccountKeyRing, passphrase: String) throws -> Data {
        guard passphrase.isEmpty == false,
              let keyRingJSON = String(data: keyRing.jsonData, encoding: .utf8)
        else { throw DayflowCoreBridgeError.invalidRootKey }
        let kit = try exportRecoveryKitKeyringJson(keyRingJson: keyRingJSON, passphrase: passphrase)
        guard let data = kit.data(using: .utf8) else { throw DayflowCoreBridgeError.unavailable }
        return data
    }

    public func restoreRecoveryKey(kit: Data, passphrase: String) throws -> Data {
        guard kit.isEmpty == false, passphrase.isEmpty == false,
              let kitJSON = String(data: kit, encoding: .utf8)
        else { throw DayflowCoreBridgeError.invalidRootKey }
        return try dayflowRustRestoreRecoveryKey(kitJSON: kitJSON, passphrase: passphrase)
    }

    public func restoreRecoveryKeyRing(kit: Data, passphrase: String) throws -> DayflowMobileAccountKeyRing {
        guard kit.isEmpty == false, passphrase.isEmpty == false,
              let kitJSON = String(data: kit, encoding: .utf8)
        else { throw DayflowCoreBridgeError.invalidRootKey }
        let keyRingJSON = try restoreRecoveryKeyringJson(kitJson: kitJSON, passphrase: passphrase)
        guard let data = keyRingJSON.data(using: .utf8) else {
            throw DayflowCoreBridgeError.unavailable
        }
        do {
            return try JSONDecoder().decode(DayflowMobileAccountKeyRing.self, from: data)
        } catch {
            throw DayflowCoreBridgeError.unavailable
        }
    }

    public func seal(
        payload: Data,
        eventID: String,
        deviceID: String,
        logicalClock: UInt64,
        accountRootKey: Data
    ) throws -> DayflowEventEnvelope {
        guard accountRootKey.count == 32 else {
            throw DayflowCoreBridgeError.invalidRootKey
        }
        guard let payloadJSON = String(data: payload, encoding: .utf8) else {
            throw DayflowCoreBridgeError.unavailable
        }
        let envelopeJSON = try sealJson(
            payloadJson: payloadJSON,
            eventId: eventID,
            deviceId: deviceID,
            logicalClock: logicalClock,
            accountRootKey: accountRootKey
        )
        guard let data = envelopeJSON.data(using: .utf8) else {
            throw DayflowCoreBridgeError.unavailable
        }
        return try JSONDecoder().decode(DayflowEventEnvelope.self, from: data)
    }

    public func seal(
        payload: Data,
        eventID: String,
        deviceID: String,
        logicalClock: UInt64,
        keyVersion: UInt32,
        accountRootKey: Data
    ) throws -> DayflowEventEnvelope {
        guard accountRootKey.count == 32, keyVersion > 0 else {
            throw DayflowCoreBridgeError.invalidRootKey
        }
        guard let payloadJSON = String(data: payload, encoding: .utf8) else {
            throw DayflowCoreBridgeError.unavailable
        }
        let envelopeJSON = try sealJsonWithKeyVersion(
            payloadJson: payloadJSON,
            eventId: eventID,
            deviceId: deviceID,
            logicalClock: logicalClock,
            keyVersion: keyVersion,
            accountRootKey: accountRootKey
        )
        guard let data = envelopeJSON.data(using: .utf8) else {
            throw DayflowCoreBridgeError.unavailable
        }
        return try JSONDecoder().decode(DayflowEventEnvelope.self, from: data)
    }

    public func wrapAccountKey(
        accountRootKey: Data,
        recipientDeviceID: String,
        recipientPublicKey: Data
    ) throws -> Data {
        guard accountRootKey.count == 32, recipientPublicKey.count == 32 else {
            throw DayflowCoreBridgeError.invalidRootKey
        }
        let wrapped = try wrapAccountKeyJson(
            accountRootKey: accountRootKey,
            recipientDeviceId: recipientDeviceID,
            recipientPublicKey: recipientPublicKey
        )
        guard let data = wrapped.data(using: .utf8) else {
            throw DayflowCoreBridgeError.unavailable
        }
        return data
    }

    public func wrapAccountKey(
        accountRootKey: Data,
        keyVersion: UInt32,
        recipientDeviceID: String,
        recipientPublicKey: Data
    ) throws -> Data {
        guard accountRootKey.count == 32, recipientPublicKey.count == 32, keyVersion > 0 else {
            throw DayflowCoreBridgeError.invalidRootKey
        }
        let wrapped = try wrapAccountKeyJsonWithVersion(
            accountRootKey: accountRootKey,
            keyVersion: keyVersion,
            recipientDeviceId: recipientDeviceID,
            recipientPublicKey: recipientPublicKey
        )
        guard let data = wrapped.data(using: .utf8) else {
            throw DayflowCoreBridgeError.unavailable
        }
        return data
    }

    public func unwrapAccountKey(wrappedKey: Data, privateKey: Data) throws -> Data {
        guard privateKey.count == 32, wrappedKey.isEmpty == false,
            let wrappedJSON = String(data: wrappedKey, encoding: .utf8)
        else {
            throw DayflowCoreBridgeError.invalidRootKey
        }
        return try unwrapAccountKeyJson(
            wrappedKeyJson: wrappedJSON,
        recipientPrivateKey: privateKey
        )
    }

    public func generateDeviceKeyMaterial() throws -> (privateKey: Data, publicKey: Data) {
        let privateKey = generateDevicePrivateKey()
        let publicKey = try devicePublicKey(privateKey: privateKey)
        guard privateKey.count == 32, publicKey.count == 32 else {
            throw DayflowCoreBridgeError.unavailable
        }
        return (privateKey, publicKey)
    }

    public func generateDeviceSigningKeyMaterial() throws -> (privateKey: Data, publicKey: Data) {
        let privateKey = generateDeviceSigningPrivateKey()
        let publicKey = try deviceSigningPublicKey(privateKey: privateKey)
        guard privateKey.count == 32, publicKey.count == 32 else {
            throw DayflowCoreBridgeError.unavailable
        }
        return (privateKey, publicKey)
    }

  public func signRequest(message: String, privateKey: Data) throws -> Data {
        guard privateKey.count == 32, message.isEmpty == false else {
            throw DayflowCoreBridgeError.invalidRootKey
        }
        let signature = try dayflowRustSignRequest(message: message, privateKey: privateKey)
        guard signature.count == 64 else {
            throw DayflowCoreBridgeError.unavailable
        }
    return signature
  }

  public func canonicalDeviceRequest(
    method: String,
    pathWithQuery: String,
    body: Data,
    timestamp: Int64,
    nonce: String,
    deviceID: String
  ) throws -> String {
    try dayflowRustCanonicalDeviceRequest(
      method: method,
      pathWithQuery: pathWithQuery,
      body: body,
      timestamp: timestamp,
      nonce: nonce,
      deviceID: deviceID
    )
  }

  public func logicalDayKey(
    timestampUnix: Int64,
    timezoneOffsetMinutes: Int32,
    boundaryHour: UInt8
  ) throws -> String {
    try logicalDayKeyFfi(
      timestampUnix: timestampUnix,
      timezoneOffsetMinutes: timezoneOffsetMinutes,
      boundaryHour: boundaryHour
    )
  }

    public func captureAllowed(
        permissionGranted: Bool,
        userPaused: Bool,
        deviceLocked: Bool,
        sleeping: Bool,
        privateContext: Bool,
        drmContent: Bool
    ) -> Bool {
        dayflowRustCaptureAllowed(
            permissionGranted: permissionGranted,
            userPaused: userPaused,
            deviceLocked: deviceLocked,
            sleeping: sleeping,
            privateContext: privateContext,
      drmContent: drmContent
    )
  }

  public func captureDecision(contextJSON: String, policyJSON: String) throws -> DayflowCaptureDecision {
    do {
      let value = try captureDecisionJson(contextJson: contextJSON, policyJson: policyJSON)
      guard let data = value.data(using: .utf8) else {
        throw DayflowCoreBridgeError.unavailable
      }
      return try JSONDecoder().decode(DayflowCaptureDecision.self, from: data)
    } catch let error as DayflowCoreBridgeError {
      throw error
    } catch {
      throw DayflowCoreBridgeError.unavailable
    }
  }
}
#endif
