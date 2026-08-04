import Foundation

private final class DayflowBackendNoRedirectDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    // Hosted provider requests may contain a bearer token and private activity
    // context. Redirects must fail closed rather than forwarding either to a
    // different host or across an HTTP downgrade.
    completionHandler(nil)
  }
}

enum DayflowBackendHTTP {
  static let noRedirectSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(
      configuration: configuration,
      delegate: DayflowBackendNoRedirectDelegate(),
      delegateQueue: nil
    )
  }()
}

enum DayflowBackendConfiguration {
  static let infoPlistEndpointKey = "DayflowBackendURL"
  static let debugOverrideDefaultsKey = "dayflowBackendURLOverride"

  static func endpoint(
    legacySavedEndpoint: String? = nil,
    bundle: Bundle = .main,
    defaults: UserDefaults = .standard
  ) -> String? {
    #if DEBUG
      if let override = normalized(defaults.string(forKey: debugOverrideDefaultsKey)) {
        return override
      }
    #endif

    if let infoEndpoint = normalized(bundle.infoDictionary?[infoPlistEndpointKey] as? String) {
      return infoEndpoint
    }

    return normalized(legacySavedEndpoint)
  }

  /// Return an account-service URL that is safe to use for bearer-token
  /// requests. The native clients all share the same trust boundary: HTTPS is
  /// required in production, and cleartext is allowed only for loopback local
  /// development. Credentials, queries, and fragments are not valid parts of
  /// a configured service base URL.
  static func validatedEndpointURL(
    from rawValue: String?
  ) -> URL? {
    guard let rawValue = normalized(rawValue),
      let url = URL(string: rawValue),
      let scheme = url.scheme?.lowercased(),
      let host = url.host,
      url.user == nil,
      url.password == nil,
      url.query == nil,
      url.fragment == nil
    else {
      return nil
    }

    guard scheme == "https"
      || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()))
    else {
      return nil
    }

    return url
  }

  static func validatedEndpointURL(
    legacySavedEndpoint: String? = nil,
    bundle: Bundle = .main,
    defaults: UserDefaults = .standard
  ) -> URL? {
    validatedEndpointURL(
      from: endpoint(
        legacySavedEndpoint: legacySavedEndpoint,
        bundle: bundle,
        defaults: defaults
      )
    )
  }

  private static func normalized(_ rawValue: String?) -> String? {
    guard let rawValue else { return nil }

    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }

    return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }
}
