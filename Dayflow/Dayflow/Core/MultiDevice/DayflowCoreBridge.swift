import DayflowCoreFFI
import Foundation

private func dayflowNulTerminated(_ data: Data) -> Data {
  var value = data
  value.append(0)
  return value
}

struct DayflowCaptureContext: Codable, Sendable {
  let permissionGranted: Bool
  let userPaused: Bool
  let deviceLocked: Bool
  let sleeping: Bool
  let privateContext: Bool
  let drmContent: Bool
  let applicationID: String?
  let windowTitle: String?

  enum CodingKeys: String, CodingKey {
    case permissionGranted = "permission_granted"
    case userPaused = "user_paused"
    case deviceLocked = "device_locked"
    case sleeping
    case privateContext = "private_context"
    case drmContent = "drm_content"
    case applicationID = "application_id"
    case windowTitle = "window_title"
  }
}

struct DayflowPrivacyPolicy: Codable, Sendable {
  let ignorePrivateContext: Bool
  let pauseOnDRM: Bool
  let blockedApplicationIDs: [String]
  let blockedWindowTitleFragments: [String]

  static let `default` = DayflowPrivacyPolicy(
    ignorePrivateContext: true,
    pauseOnDRM: true,
    blockedApplicationIDs: [],
    blockedWindowTitleFragments: []
  )

  enum CodingKeys: String, CodingKey {
    case ignorePrivateContext = "ignore_private_context"
    case pauseOnDRM = "pause_on_drm"
    case blockedApplicationIDs = "blocked_application_ids"
    case blockedWindowTitleFragments = "blocked_window_title_fragments"
  }
}

struct DayflowCaptureDecision: Codable, Equatable, Sendable {
  let allowed: Bool
  let reason: String
}

/// The Mac-side native boundary for the shared Rust core.
///
/// The relay never sees the root key. Swift only hands it to the synchronous
/// Rust call, and the returned envelope is the only value that crosses back
/// into the GRDB/outbox layer.
struct DayflowCoreBridge: Sendable {
  static let shared = DayflowCoreBridge()

  var version: String {
    guard let pointer = dayflow_core_version() else { return "unavailable" }
    defer { dayflow_core_free_string(pointer) }
    return String(cString: pointer)
  }

  func seal(
    payload: Data,
    eventID: String,
    deviceID: String,
    logicalClock: UInt64,
    accountRootKey: Data
  ) throws -> DayflowEventEnvelope {
    guard accountRootKey.count == 32 else {
      throw DayflowCoreBridgeError.invalidRootKey
    }
    guard eventID.isEmpty == false, deviceID.isEmpty == false, logicalClock > 0 else {
      throw DayflowCoreBridgeError.invalidEventMetadata
    }
    let payloadData = dayflowNulTerminated(payload)

    let json = try invokeString {
      eventID.withCString { eventIDPointer in
        deviceID.withCString { deviceIDPointer in
          accountRootKey.withUnsafeBytes { keyBuffer in
            payloadData.withUnsafeBytes { payloadBuffer in
              guard
                let keyPointer = keyBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                let payloadPointer = payloadBuffer.baseAddress?.assumingMemoryBound(to: CChar.self)
              else {
                return nil
              }

              return dayflow_core_seal_json(
                payloadPointer,
                eventIDPointer,
                deviceIDPointer,
                logicalClock,
                keyPointer,
                accountRootKey.count
              )
            }
          }
        }
      }
    }

    let envelopeData = Data(json.utf8)
    do {
      return try JSONDecoder().decode(DayflowEventEnvelope.self, from: envelopeData)
    } catch {
      throw DayflowCoreBridgeError.coreFailure(json)
    }
  }

  func seal(
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
    guard eventID.isEmpty == false, deviceID.isEmpty == false, logicalClock > 0 else {
      throw DayflowCoreBridgeError.invalidEventMetadata
    }
    let payloadData = dayflowNulTerminated(payload)

    let json = try invokeString {
      eventID.withCString { eventIDPointer in
        deviceID.withCString { deviceIDPointer in
          accountRootKey.withUnsafeBytes { keyBuffer in
            payloadData.withUnsafeBytes { payloadBuffer in
              guard
                let keyPointer = keyBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                let payloadPointer = payloadBuffer.baseAddress?.assumingMemoryBound(to: CChar.self)
              else {
                return nil
              }

              return dayflow_core_seal_key_version_json(
                payloadPointer,
                eventIDPointer,
                deviceIDPointer,
                logicalClock,
                keyVersion,
                keyPointer,
                accountRootKey.count
              )
            }
          }
        }
      }
    }

    do {
      return try JSONDecoder().decode(DayflowEventEnvelope.self, from: Data(json.utf8))
    } catch {
      throw DayflowCoreBridgeError.coreFailure(json)
    }
  }

  func project(envelopes: [DayflowEventEnvelope], accountRootKey: Data) throws -> Data {
    guard accountRootKey.count == 32 else {
      throw DayflowCoreBridgeError.invalidRootKey
    }

    let envelopeData = dayflowNulTerminated(try JSONEncoder().encode(envelopes))
    let json = try invokeString {
      accountRootKey.withUnsafeBytes { keyBuffer in
        envelopeData.withUnsafeBytes { envelopeBuffer in
          guard
            let keyPointer = keyBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
            let envelopePointer = envelopeBuffer.baseAddress?.assumingMemoryBound(to: CChar.self)
          else {
            return nil
          }

          return dayflow_core_project_json(
            envelopePointer,
            keyPointer,
            accountRootKey.count
          )
        }
      }
    }

    guard let data = json.data(using: .utf8) else {
      throw DayflowCoreBridgeError.coreFailure("Rust returned invalid UTF-8")
    }
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = object["error"] as? String
    {
      throw DayflowCoreBridgeError.coreFailure(error)
    }
    return Data(json.utf8)
  }

  func project(envelopes: [DayflowEventEnvelope], keyRing: DayflowAccountKeyRing) throws -> Data {
    let envelopeData = dayflowNulTerminated(try JSONEncoder().encode(envelopes))
    let keyRingData = dayflowNulTerminated(keyRing.jsonData)
    guard envelopeData.isEmpty == false, keyRingData.isEmpty == false else {
      throw DayflowCoreBridgeError.invalidRootKey
    }
    let json = try invokeString {
      envelopeData.withUnsafeBytes { envelopeBuffer in
        keyRingData.withUnsafeBytes { keyRingBuffer in
          guard
            let envelopePointer = envelopeBuffer.baseAddress?.assumingMemoryBound(to: CChar.self),
            let keyRingPointer = keyRingBuffer.baseAddress?.assumingMemoryBound(to: CChar.self)
          else {
            return nil
          }
          return dayflow_core_project_keyring_json(envelopePointer, keyRingPointer)
        }
      }
    }
    guard let data = json.data(using: .utf8) else {
      throw DayflowCoreBridgeError.coreFailure("Rust returned invalid UTF-8")
    }
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = object["error"] as? String
    {
      throw DayflowCoreBridgeError.coreFailure(error)
    }
    return data
  }

  /// Re-encrypts a local-workspace envelope for an admitted account key-ring.
  /// Event identity and logical clocks remain unchanged; only the authenticated
  /// ciphertext and key version may change.
  func rekey(
    envelopes: [DayflowEventEnvelope],
    sourceKeyRing: DayflowAccountKeyRing,
    destinationKeyRing: DayflowAccountKeyRing
  ) throws -> [DayflowEventEnvelope] {
    guard envelopes.isEmpty == false,
      sourceKeyRing.jsonData.isEmpty == false,
      destinationKeyRing.jsonData.isEmpty == false
    else {
      return []
    }

    let envelopeData = dayflowNulTerminated(try JSONEncoder().encode(envelopes))
    let sourceKeyRingData = dayflowNulTerminated(sourceKeyRing.jsonData)
    let destinationKeyRingData = dayflowNulTerminated(destinationKeyRing.jsonData)
    let json = try invokeString {
      envelopeData.withUnsafeBytes { envelopeBuffer in
        sourceKeyRingData.withUnsafeBytes { sourceBuffer in
          destinationKeyRingData.withUnsafeBytes { destinationBuffer in
            guard
              let envelopePointer = envelopeBuffer.baseAddress?.assumingMemoryBound(to: CChar.self),
              let sourcePointer = sourceBuffer.baseAddress?.assumingMemoryBound(to: CChar.self),
              let destinationPointer = destinationBuffer.baseAddress?.assumingMemoryBound(to: CChar.self)
            else {
              return nil
            }
            return dayflow_core_rekey_envelopes_json(
              envelopePointer,
              sourcePointer,
              destinationPointer
            )
          }
        }
      }
    }

    do {
      return try JSONDecoder().decode([DayflowEventEnvelope].self, from: Data(json.utf8))
    } catch {
      throw DayflowCoreBridgeError.coreFailure(json)
    }
  }

  func captureDecision(
    context: DayflowCaptureContext,
    policy: DayflowPrivacyPolicy = .default
  ) throws -> DayflowCaptureDecision {
    let contextJSON = dayflowNulTerminated(try JSONEncoder().encode(context))
    let policyJSON = dayflowNulTerminated(try JSONEncoder().encode(policy))
    let json = try invokeString {
      contextJSON.withUnsafeBytes { contextBuffer in
        policyJSON.withUnsafeBytes { policyBuffer in
          guard
            let contextPointer = contextBuffer.baseAddress?.assumingMemoryBound(to: CChar.self),
            let policyPointer = policyBuffer.baseAddress?.assumingMemoryBound(to: CChar.self)
          else {
            return nil
          }
          return dayflow_core_capture_decision_json(contextPointer, policyPointer)
        }
      }
    }
    do {
      return try JSONDecoder().decode(DayflowCaptureDecision.self, from: Data(json.utf8))
    } catch {
      throw DayflowCoreBridgeError.coreFailure(json)
    }
  }

  /// Returns the canonical logical day from the shared Rust boundary.
  ///
  /// The offset is explicit so a replay on another device does not silently
  /// apply the host's timezone. Live Mac events use the offset that was
  /// active for the captured timestamp.
  func logicalDayKey(
    timestampUnix: Int64,
    timezoneOffsetMinutes: Int32,
    boundaryHour: UInt8 = 4
  ) throws -> String {
    let json = try invokeString {
      dayflow_core_logical_day_key(
        timestampUnix,
        timezoneOffsetMinutes,
        boundaryHour
      )
    }
    guard
      let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      let day = object["day"] as? String,
      day.isEmpty == false
    else {
      throw DayflowCoreBridgeError.coreFailure(json)
    }
    return day
  }

  /// Convenience wrapper for a Mac timestamp using the local offset at that
  /// instant, including daylight-saving transitions.
  func logicalDayKey(
    forUnixTimestamp timestampUnix: Int64,
    timeZone: TimeZone = .current,
    boundaryHour: UInt8 = 4
  ) throws -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestampUnix))
    let offsetMinutes = timeZone.secondsFromGMT(for: date) / 60
    return try logicalDayKey(
      timestampUnix: timestampUnix,
      timezoneOffsetMinutes: Int32(offsetMinutes),
      boundaryHour: boundaryHour
    )
  }

  func wrapAccountKey(
    accountRootKey: Data,
    recipientDeviceID: String,
    recipientPublicKey: Data
  ) throws -> Data {
    guard accountRootKey.count == 32, recipientPublicKey.count == 32 else {
      throw DayflowCoreBridgeError.invalidRootKey
    }
    guard recipientDeviceID.isEmpty == false else {
      throw DayflowCoreBridgeError.invalidEventMetadata
    }

    let json = try invokeString {
      accountRootKey.withUnsafeBytes { rootBuffer in
        recipientPublicKey.withUnsafeBytes { publicBuffer in
          recipientDeviceID.withCString { deviceIDPointer in
            guard
              let rootPointer = rootBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
              let publicPointer = publicBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            else {
              return nil
            }
            return dayflow_core_wrap_account_key_json(
              rootPointer,
              accountRootKey.count,
              deviceIDPointer,
              publicPointer,
              recipientPublicKey.count
            )
          }
        }
      }
    }
    return Data(json.utf8)
  }

  func wrapAccountKey(
    accountRootKey: Data,
    keyVersion: UInt32,
    recipientDeviceID: String,
    recipientPublicKey: Data
  ) throws -> Data {
    guard accountRootKey.count == 32, recipientPublicKey.count == 32, keyVersion > 0 else {
      throw DayflowCoreBridgeError.invalidRootKey
    }
    guard recipientDeviceID.isEmpty == false else {
      throw DayflowCoreBridgeError.invalidEventMetadata
    }
    let json = try invokeString {
      accountRootKey.withUnsafeBytes { rootBuffer in
        recipientPublicKey.withUnsafeBytes { publicBuffer in
          recipientDeviceID.withCString { deviceIDPointer in
            guard
              let rootPointer = rootBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
              let publicPointer = publicBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            else {
              return nil
            }
            return dayflow_core_wrap_account_key_versioned_json(
              rootPointer,
              accountRootKey.count,
              keyVersion,
              deviceIDPointer,
              publicPointer,
              recipientPublicKey.count
            )
          }
        }
      }
    }
    return Data(json.utf8)
  }

  func unwrapAccountKey(wrappedKey: Data, privateKey: Data) throws -> Data {
    guard privateKey.count == 32, wrappedKey.isEmpty == false else {
      throw DayflowCoreBridgeError.invalidRootKey
    }
    let wrappedKeyData = dayflowNulTerminated(wrappedKey)

    let json = try invokeString {
      wrappedKeyData.withUnsafeBytes { wrappedBuffer in
        privateKey.withUnsafeBytes { privateBuffer in
          guard
            let wrappedPointer = wrappedBuffer.baseAddress?.assumingMemoryBound(to: CChar.self),
            let privatePointer = privateBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
          else {
            return nil
          }
          return dayflow_core_unwrap_account_key_json(
            wrappedPointer,
            privatePointer,
            privateKey.count
          )
        }
      }
    }

    guard
      let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      let encodedKey = object["root_key"] as? String,
      let rootKey = Data(base64Encoded: encodedKey),
      rootKey.count == 32
    else {
      throw DayflowCoreBridgeError.coreFailure("Rust returned an invalid wrapped account key")
    }
    return rootKey
  }

  func unwrapAccountKeyVersioned(
    wrappedKey: Data,
    privateKey: Data
  ) throws -> (keyVersion: UInt32, rootKey: Data) {
    let rootKey = try unwrapAccountKey(wrappedKey: wrappedKey, privateKey: privateKey)
    guard
      let object = try JSONSerialization.jsonObject(with: wrappedKey) as? [String: Any],
      let keyVersion = object["key_version"] as? UInt32 ?? (object["key_version"] as? NSNumber)?.uint32Value,
      keyVersion > 0
    else {
      // Old wrapped-key documents predate the explicit field and are v1.
      return (1, rootKey)
    }
    return (keyVersion, rootKey)
  }

  func exportRecoveryKit(accountRootKey: Data, passphrase: String) throws -> Data {
    guard accountRootKey.count == 32, passphrase.isEmpty == false else {
      throw DayflowCoreBridgeError.invalidRootKey
    }

    let json = try invokeString {
      accountRootKey.withUnsafeBytes { keyBuffer in
        passphrase.withCString { passphrasePointer in
          guard let keyPointer = keyBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return nil
          }
          return dayflow_core_export_recovery_kit_json(
            keyPointer,
            accountRootKey.count,
            passphrasePointer
          )
        }
      }
    }
    return Data(json.utf8)
  }

  func restoreRecoveryKey(kit: Data, passphrase: String) throws -> Data {
    guard kit.isEmpty == false, passphrase.isEmpty == false else {
      throw DayflowCoreBridgeError.invalidEventMetadata
    }

    let json = try invokeString {
      dayflowNulTerminated(kit).withUnsafeBytes { kitBuffer in
        passphrase.withCString { passphrasePointer in
          guard let kitPointer = kitBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
            return nil
          }
          return dayflow_core_restore_recovery_key_json(kitPointer, passphrasePointer)
        }
      }
    }

    guard
      let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      let encodedKey = object["root_key"] as? String,
      let rootKey = Data(base64Encoded: encodedKey),
      rootKey.count == 32
    else {
      throw DayflowCoreBridgeError.coreFailure("Rust returned an invalid recovery key")
    }
    return rootKey
  }

  func exportRecoveryKit(keyRing: DayflowAccountKeyRing, passphrase: String) throws -> Data {
    guard keyRing.jsonData.isEmpty == false, passphrase.isEmpty == false else {
      throw DayflowCoreBridgeError.invalidRootKey
    }
    let keyRingData = dayflowNulTerminated(keyRing.jsonData)
    let json = try invokeString {
      keyRingData.withUnsafeBytes { keyRingBuffer in
        passphrase.withCString { passphrasePointer in
          guard let keyRingPointer = keyRingBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
            return nil
          }
          return dayflow_core_export_recovery_kit_keyring_json(keyRingPointer, passphrasePointer)
        }
      }
    }
    return Data(json.utf8)
  }

  func restoreRecoveryKeyRing(kit: Data, passphrase: String) throws -> DayflowAccountKeyRing {
    guard kit.isEmpty == false, passphrase.isEmpty == false else {
      throw DayflowCoreBridgeError.invalidEventMetadata
    }
    let json = try invokeString {
      dayflowNulTerminated(kit).withUnsafeBytes { kitBuffer in
        passphrase.withCString { passphrasePointer in
          guard let kitPointer = kitBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
            return nil
          }
          return dayflow_core_restore_recovery_keyring_json(kitPointer, passphrasePointer)
        }
      }
    }
    guard let data = json.data(using: .utf8) else {
      throw DayflowCoreBridgeError.coreFailure("Rust returned invalid key-ring UTF-8")
    }
    do {
      return try JSONDecoder().decode(DayflowAccountKeyRing.self, from: data)
    } catch {
      throw DayflowCoreBridgeError.coreFailure(json)
    }
  }

  func generateDeviceKeyMaterial() throws -> (privateKey: Data, publicKey: Data) {
    let json = try invokeString {
      dayflow_core_generate_device_keypair_json()
    }
    guard
      let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      let privateKeyString = object["private_key"] as? String,
      let publicKeyString = object["public_key"] as? String,
      let privateKey = Data(base64Encoded: privateKeyString),
      let publicKey = Data(base64Encoded: publicKeyString),
      privateKey.count == 32,
      publicKey.count == 32
    else {
      throw DayflowCoreBridgeError.coreFailure("Rust returned invalid device key material")
    }
    return (privateKey, publicKey)
  }

  func generateAccountRootKey() throws -> Data {
    let json = try invokeString {
      dayflow_core_generate_account_root_key_json()
    }
    guard
      let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      let encodedKey = object["root_key"] as? String,
      let key = Data(base64Encoded: encodedKey),
      key.count == 32
    else {
      throw DayflowCoreBridgeError.coreFailure("Rust returned an invalid account root key")
    }
    return key
  }

  func generateDeviceSigningKeyMaterial() throws -> (privateKey: Data, publicKey: Data) {
    let json = try invokeString {
      dayflow_core_generate_device_signing_keypair_json()
    }
    guard
      let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      let privateKeyString = object["private_key"] as? String,
      let publicKeyString = object["public_key"] as? String,
      let privateKey = Data(base64Encoded: privateKeyString),
      let publicKey = Data(base64Encoded: publicKeyString),
      privateKey.count == 32,
      publicKey.count == 32
    else {
      throw DayflowCoreBridgeError.coreFailure("Rust returned invalid device signing key material")
    }
    return (privateKey, publicKey)
  }

  func canonicalDeviceRequest(
    method: String,
    pathWithQuery: String,
    body: Data,
    timestamp: Int64,
    nonce: String,
    deviceID: String
  ) throws -> String {
    let json = try invokeString {
      method.withCString { methodPointer in
        pathWithQuery.withCString { pathPointer in
          nonce.withCString { noncePointer in
            deviceID.withCString { deviceIDPointer in
              body.withUnsafeBytes { bodyBuffer in
                dayflow_core_canonical_device_request_json(
                  methodPointer,
                  pathPointer,
                  bodyBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                  body.count,
                  timestamp,
                  noncePointer,
                  deviceIDPointer
                )
              }
            }
          }
        }
      }
    }
    guard
      let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      let request = object["request"] as? String,
      request.isEmpty == false
    else {
      throw DayflowCoreBridgeError.coreFailure(json)
    }
    return request
  }

  func signRequest(message: String, privateKey: Data) throws -> Data {
    guard privateKey.count == 32, message.isEmpty == false else {
      throw DayflowCoreBridgeError.invalidEventMetadata
    }
    let json = try invokeString {
      message.withCString { messagePointer in
        privateKey.withUnsafeBytes { keyBuffer in
          guard let keyPointer = keyBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return nil
          }
          return dayflow_core_sign_request_json(
            messagePointer,
            keyPointer,
            privateKey.count
          )
        }
      }
    }
    guard
      let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      let signatureString = object["signature"] as? String,
      let signature = Data(base64Encoded: signatureString),
      signature.count == 64
    else {
      throw DayflowCoreBridgeError.coreFailure("Rust returned an invalid request signature")
    }
    return signature
  }

  private func invokeString(
    _ call: () -> UnsafeMutablePointer<CChar>?
  ) throws -> String {
    let pointer = call()
    guard let pointer else {
      throw DayflowCoreBridgeError.unavailable
    }
    defer { dayflow_core_free_string(pointer) }

    let value = String(cString: pointer)
    if let error = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any],
      let message = error["error"] as? String
    {
      throw DayflowCoreBridgeError.coreFailure(message)
    }
    return value
  }
}

enum DayflowCoreBridgeError: LocalizedError, Equatable {
  case unavailable
  case invalidRootKey
  case invalidEventMetadata
  case coreFailure(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      return "The shared Dayflow core is not available on this device."
    case .invalidRootKey:
      return "The account encryption key is invalid."
    case .invalidEventMetadata:
      return "The event metadata is incomplete."
    case .coreFailure(let message):
      return "Dayflow core failed: \(message)"
    }
  }
}
