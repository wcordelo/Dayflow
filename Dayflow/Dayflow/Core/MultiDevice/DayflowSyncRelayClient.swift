import Foundation

/// A configured relay URL must not be able to redirect a native client to a
/// different host or from HTTPS to HTTP. The relay is an opaque transport, so
/// following a redirect here would silently change the trust boundary.
private final class DayflowSyncNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

private enum DayflowSyncHTTP {
  static let noRedirectSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(
      configuration: configuration,
      delegate: DayflowSyncNoRedirectDelegate(),
      delegateQueue: nil
    )
  }()
}

enum DayflowSyncRelayConfiguration {
  static let overrideKey = "dayflowSyncRelayURLOverride"
  static let savedKey = "dayflowSyncRelayURL"
  static let infoPlistKey = "DayflowSyncRelayURL"

  static var baseURL: URL? {
    #if DEBUG
      if let override = UserDefaults.standard.string(forKey: overrideKey),
        let url = normalizedURL(override)
      {
        return url
      }
    #endif

    if let saved = UserDefaults.standard.string(forKey: savedKey),
      let url = normalizedURL(saved)
    {
      return url
    }
    if let bundled = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String {
      return normalizedURL(bundled)
    }
    return nil
  }

  static func setBaseURL(_ value: String) {
    UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: savedKey)
  }

  private static func normalizedURL(_ rawValue: String) -> URL? {
    DayflowBackendConfiguration.validatedEndpointURL(from: rawValue)
  }
}

struct DayflowRelayDevice: Codable, Equatable, Sendable {
  let deviceID: String
  let publicKey: String
  let signingPublicKey: String
  let displayName: String
  let platform: String
  let status: String
  let createdAt: Int64
  let lastSeenAt: Int64
  /// Registration-only admission signal. Device-list responses from older
  /// relays omit this field, so it remains optional and only an explicit true
  /// value can authorize first-device key generation.
  let keyBootstrapRequired: Bool?

  enum CodingKeys: String, CodingKey {
    case deviceID = "device_id"
    case publicKey = "public_key"
    case signingPublicKey = "signing_public_key"
    case displayName = "display_name"
    case platform
    case status
    case createdAt = "created_at"
    case lastSeenAt = "last_seen_at"
    case keyBootstrapRequired = "key_bootstrap_required"
  }
}

struct DayflowRelayPushResponse: Codable, Equatable, Sendable {
  let acceptedEventIDs: [String]
  let duplicateEventIDs: [String]
  let cursor: String
  let notificationCount: Int

  enum CodingKeys: String, CodingKey {
    case acceptedEventIDs = "accepted_event_ids"
    case duplicateEventIDs = "duplicate_event_ids"
    case cursor
    case notificationCount = "notification_count"
  }
}

struct DayflowRelayPulledEvent: Codable, Equatable, Sendable {
  let sequence: Int64
  let envelope: DayflowEventEnvelope
}

struct DayflowRelayWrappedKey: Codable, Equatable, Sendable {
  let deviceID: String
  let keyVersion: UInt32
  let wrappedAccountKey: String
  let wrappedByDeviceID: String
  let createdAt: Int64

  enum CodingKeys: String, CodingKey {
    case deviceID = "device_id"
    case keyVersion = "key_version"
    case wrappedAccountKey = "wrapped_account_key"
    case wrappedByDeviceID = "wrapped_by_device_id"
    case createdAt = "created_at"
  }
}

struct DayflowRelayPullResponse: Codable, Equatable, Sendable {
  let cursor: String
  let events: [DayflowRelayPulledEvent]
}

struct DayflowRelayNotificationHint: Codable, Equatable, Sendable {
  let sequence: Int64
  let kind: String
}

struct DayflowRelayNotificationHintsResponse: Codable, Equatable, Sendable {
  let cursor: String
  let hints: [DayflowRelayNotificationHint]
}

struct DayflowRelayPushRegistrationResult: Codable, Equatable, Sendable {
  let deviceID: String
  let platform: String
  let registered: Bool

  enum CodingKeys: String, CodingKey {
    case deviceID = "device_id"
    case platform
    case registered
  }
}

enum DayflowSyncRelayClientError: LocalizedError, Equatable {
  case invalidBaseURL
  case invalidResponse
  case server(status: Int, message: String)

  var errorDescription: String? {
    switch self {
    case .invalidBaseURL:
      return "Encrypted sync is not configured for this build."
    case .invalidResponse:
      return "The sync relay returned an invalid response."
    case .server(let status, let message):
      return "Sync relay error (\(status)): \(message)"
    }
  }
}

struct DayflowSyncRelayClient: Sendable {
  let baseURL: URL
  private let session: URLSession

  init(baseURL: URL, session: URLSession = DayflowSyncHTTP.noRedirectSession) {
    self.baseURL = baseURL
    self.session = session
  }

  func registerDevice(
    deviceID: String,
    publicKey: Data,
    signingPublicKey: Data,
    displayName: String,
    token: String,
    recoveryMode: Bool = false
  ) async throws -> DayflowRelayDevice {
    try await request(
      path: "/v1/sync/devices",
      method: "POST",
      token: token,
      deviceID: nil,
      body: try JSONSerialization.data(withJSONObject: [
        "device_id": deviceID,
        "public_key": publicKey.base64EncodedString(),
        "signing_public_key": signingPublicKey.base64EncodedString(),
        "display_name": displayName,
        "platform": "macos",
        "recovery_mode": recoveryMode,
      ])
    )
  }

  func listDevices(token: String) async throws -> [DayflowRelayDevice] {
    try await request(path: "/v1/sync/devices", method: "GET", token: token, deviceID: nil, body: nil)
  }

  func approveDevice(
    targetDeviceID: String,
    keyVersion: UInt32,
    wrappedAccountKey: Data,
    token: String,
    approverDeviceID: String,
    signingPrivateKey: Data
  ) async throws -> DayflowRelayDevice {
    try await request(
      path: "/v1/sync/devices/\(encodedPathComponent(targetDeviceID))/approve",
      method: "POST",
      token: token,
      deviceID: approverDeviceID,
      body: try JSONSerialization.data(withJSONObject: [
        "key_version": keyVersion,
        "wrapped_account_key": wrappedAccountKey.base64EncodedString(),
        "wrapped_by_device_id": approverDeviceID,
      ]),
      signingPrivateKey: signingPrivateKey
    )
  }

  func revokeDevice(
    targetDeviceID: String,
    token: String,
    actorDeviceID: String,
    signingPrivateKey: Data
  ) async throws -> DayflowRelayDevice {
    try await request(
      path: "/v1/sync/devices/\(encodedPathComponent(targetDeviceID))/revoke",
      method: "POST",
      token: token,
      deviceID: actorDeviceID,
      body: nil,
      signingPrivateKey: signingPrivateKey
    )
  }

  func wrappedAccountKey(
    deviceID: String,
    token: String,
    signingPrivateKey: Data
  ) async throws -> DayflowRelayWrappedKey? {
    try await request(
      path: "/v1/sync/devices/\(encodedPathComponent(deviceID))/wrapped-key",
      method: "GET",
      token: token,
      deviceID: deviceID,
      body: nil,
      signingPrivateKey: signingPrivateKey
    )
  }

  func wrappedAccountKeys(
    deviceID: String,
    token: String,
    signingPrivateKey: Data
  ) async throws -> [DayflowRelayWrappedKey] {
    do {
      return try await request(
        path: "/v1/sync/devices/\(encodedPathComponent(deviceID))/wrapped-keys",
        method: "GET",
        token: token,
        deviceID: deviceID,
        body: nil,
        signingPrivateKey: signingPrivateKey
      )
    } catch let error as DayflowSyncRelayClientError {
      guard case .server(let status, _) = error, status == 404 else { throw error }
      guard let legacy = try await wrappedAccountKey(
        deviceID: deviceID,
        token: token,
        signingPrivateKey: signingPrivateKey
      ) else { return [] }
      return [legacy]
    }
  }

  func push(
    envelopes: [DayflowEventEnvelope],
    token: String,
    deviceID: String,
    signingPrivateKey: Data
  ) async throws -> DayflowRelayPushResponse {
    try await request(
      path: "/v1/sync/events",
      method: "POST",
      token: token,
      deviceID: deviceID,
      body: try JSONEncoder().encode(DayflowRelayEventBatch(envelopes: envelopes)),
      signingPrivateKey: signingPrivateKey
    )
  }

  func pull(
    cursor: String?,
    token: String,
    deviceID: String,
    signingPrivateKey: Data
  ) async throws -> DayflowRelayPullResponse {
    var path = "/v1/sync/events?limit=100"
    if let cursor, cursor.isEmpty == false {
      path += "&cursor=\(Self.encodedQueryComponent(cursor))"
    }
    return try await request(
      path: path,
      method: "GET",
      token: token,
      deviceID: deviceID,
      body: nil,
      signingPrivateKey: signingPrivateKey
    )
  }

  /// Pulls content-free wake hints. The hint cursor is independent from the
  /// event cursor so consuming a wake signal can never skip an encrypted
  /// event. Callers persist the returned cursor only after decoding succeeds.
  func pullNotificationHints(
    cursor: String?,
    token: String,
    deviceID: String,
    signingPrivateKey: Data
  ) async throws -> DayflowRelayNotificationHintsResponse {
    var path = "/v1/sync/notifications?limit=100"
    if let cursor, cursor.isEmpty == false {
      path += "&cursor=\(Self.encodedQueryComponent(cursor))"
    }
    return try await request(
      path: path,
      method: "GET",
      token: token,
      deviceID: deviceID,
      body: nil,
      signingPrivateKey: signingPrivateKey
    )
  }

  func registerPushToken(
    pushToken: String,
    token: String,
    deviceID: String,
    signingPrivateKey: Data
  ) async throws -> DayflowRelayPushRegistrationResult {
    guard pushToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
      throw DayflowSyncRelayClientError.invalidResponse
    }
    return try await request(
      path: "/v1/sync/notifications",
      method: "PUT",
      token: token,
      deviceID: deviceID,
      body: try JSONEncoder().encode(["token": pushToken]),
      signingPrivateKey: signingPrivateKey
    )
  }

  func unregisterPushToken(
    token: String,
    deviceID: String,
    signingPrivateKey: Data
  ) async throws -> DayflowRelayPushRegistrationResult {
    try await request(
      path: "/v1/sync/notifications",
      method: "DELETE",
      token: token,
      deviceID: deviceID,
      body: nil,
      signingPrivateKey: signingPrivateKey
    )
  }

  private func request<Response: Decodable>(
    path: String,
    method: String,
    token: String,
    deviceID: String?,
    body: Data?,
    signingPrivateKey: Data? = nil
  ) async throws -> Response {
    guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
      throw DayflowSyncRelayClientError.invalidBaseURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 30
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let deviceID {
      request.setValue(deviceID, forHTTPHeaderField: "X-Dayflow-Device-ID")
    }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = body
    }
    if let deviceID {
      guard let signingPrivateKey, signingPrivateKey.count == 32 else {
        throw DayflowSyncRelayClientError.invalidResponse
      }
      let timestamp = Int(Date().timeIntervalSince1970)
      let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
      // `path` is the exact relative path used to create the request. Signing
      // it avoids Foundation normalizing percent escapes differently from the
      // Worker URL parser.
      let pathWithQuery = path
      let message = try DayflowCoreBridge.shared.canonicalDeviceRequest(
        method: method,
        pathWithQuery: pathWithQuery,
        body: body ?? Data(),
        timestamp: Int64(timestamp),
        nonce: nonce,
        deviceID: deviceID
      )
      let signature = try DayflowCoreBridge.shared.signRequest(
        message: message,
        privateKey: signingPrivateKey
      )
      request.setValue(String(timestamp), forHTTPHeaderField: "X-Dayflow-Device-Timestamp")
      request.setValue(nonce, forHTTPHeaderField: "X-Dayflow-Device-Nonce")
      request.setValue(signature.base64EncodedString(), forHTTPHeaderField: "X-Dayflow-Device-Signature")
    }

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw DayflowSyncRelayClientError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      let message = (try? JSONDecoder().decode(DayflowRelayErrorResponse.self, from: data))?.message
        ?? "The relay could not complete the request."
      throw DayflowSyncRelayClientError.server(status: httpResponse.statusCode, message: message)
    }
    do {
      return try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw DayflowSyncRelayClientError.invalidResponse
    }
  }

  private func encodedPathComponent(_ value: String) -> String {
    // `.urlPathAllowed` includes `/`, which would let a malformed device ID
    // escape the route segment. Device IDs are normally UUIDs, but relay data
    // is still untrusted input and must remain one encoded path component.
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  private static func encodedQueryComponent(_ value: String) -> String {
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }
}

private struct DayflowRelayErrorResponse: Decodable {
  let message: String
}

private struct DayflowRelayEventBatch: Encodable {
  let envelopes: [DayflowEventEnvelope]
}
