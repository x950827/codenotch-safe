import Foundation

enum CursorBoundaryError: Error {
    case invalidEndpoint
    case invalidCookie
}

enum CursorEndpoint {
    static let url = URL(string: "https://cursor.com/api/usage-summary")!

    static func makeRequest(cookie: String, target: URL = url) throws -> URLRequest {
        guard isAllowed(target) else { throw CursorBoundaryError.invalidEndpoint }
        guard !cookie.isEmpty,
              !cookie.contains("\r"),
              !cookie.contains("\n")
        else { throw CursorBoundaryError.invalidCookie }

        var request = URLRequest(
            url: target,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        return configuration
    }

    static func isAllowed(_ target: URL) -> Bool {
        guard let components = URLComponents(url: target, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme == "https"
            && components.host == "cursor.com"
            && components.port == nil
            && components.user == nil
            && components.password == nil
            && components.percentEncodedPath == "/api/usage-summary"
            && components.percentEncodedQuery == nil
            && components.fragment == nil
    }
}

final class RedirectRejectingSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
