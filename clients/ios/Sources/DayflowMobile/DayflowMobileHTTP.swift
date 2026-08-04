import Foundation

/// Native account, sync, and provider requests must not silently follow a
/// server redirect to a different host or transport. Endpoint validation is
/// performed before the request too; this delegate closes the redirect gap.
private final class DayflowNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

public enum DayflowMobileHTTP {
    /// Cursor values are opaque relay data and must stay one query parameter.
    /// `URLCharacterSet.urlQueryAllowed` includes separators such as `&` and
    /// `=`, so it is too broad for embedding an untrusted cursor in a URL.
    static func encodedQueryComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    public static func isAllowedEndpoint(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host,
              host.isEmpty == false,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return false
        }
        if scheme == "https" { return true }
        return scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
    }

    public static let noRedirectSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(
            configuration: configuration,
            delegate: DayflowNoRedirectDelegate(),
            delegateQueue: nil
        )
    }()
}
