import Foundation

enum OpenCodeBoundaryError: Error {
    case invalidEndpoint
    case invalidToken
}

enum OpenCodeEndpoint {
    static let url = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    static func makeRequest(token: String, target: URL = url) throws -> URLRequest {
        guard isAllowed(target) else { throw OpenCodeBoundaryError.invalidEndpoint }
        guard !token.isEmpty,
              !token.contains("\r"),
              !token.contains("\n")
        else { throw OpenCodeBoundaryError.invalidToken }

        var request = URLRequest(
            url: target,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
            && components.host == "opencode.ai"
            && components.port == nil
            && components.user == nil
            && components.password == nil
            && components.percentEncodedPath == "/zen/go/v1/usage"
            && components.percentEncodedQuery == nil
            && components.fragment == nil
    }

    /// How long to wait after a 429 — a minute, doubling per consecutive
    /// limit, capped so it always recovers on its own. The server's own hint
    /// is honoured only as a floor-raiser, for the reason Claude's records.
    static func backoff(forAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let floor: TimeInterval = 60
        let ceiling: TimeInterval = 15 * 60
        let doubled = floor * pow(2, Double(min(attempt, 4)))
        return min(ceiling, max(doubled, retryAfter ?? 0))
    }

    /// `Retry-After` is either a number of seconds or an HTTP date.
    static func retryAfter(from response: URLResponse?) -> TimeInterval? {
        guard let header = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        else { return nil }

        if let seconds = TimeInterval(header) { return max(0, seconds) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    // MARK: - Stubbed session (tests only)

    /// One canned response for the request a Safe test fires.
    enum StubbedResponse {
        case success(body: String)
        case status(Int, headers: [String: String], body: String)
        case redirected(to: String)
    }

    /// Builds a `URLSession` whose every data task hands back the supplied
    /// response. Used only by `SafeTests` — the production path is
    /// `makeConfiguration()` plus `RedirectRejectingSessionDelegate`.
    static func makeStubbedSession(
        respond: @escaping @Sendable (URLRequest) -> StubbedResponse
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubbedProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        StubbedProtocol.handler = respond
        return URLSession(configuration: configuration)
    }
}

private final class StubbedProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> OpenCodeEndpoint.StubbedResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client, let handler = StubbedProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch handler(request) {
        case .success(let body):
            respond(status: 200, headers: ["Content-Type": "application/json"], body: body)
        case .status(let code, let headers, let body):
            respond(status: code, headers: headers, body: body)
        case .redirected(let target):
            guard URL(string: target) != nil else {
                client.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let response = HTTPURLResponse(
                url: request.url ?? OpenCodeEndpoint.url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target]
            ) ?? HTTPURLResponse()
            client.urlProtocol(self, didReceive: response,
                               cacheStoragePolicy: .notAllowed)
        }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func respond(status: Int, headers: [String: String], body: String) {
        guard let client else { return }
        let url = request.url ?? OpenCodeEndpoint.url
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) ?? HTTPURLResponse()
        client.urlProtocol(self, didReceive: response,
                           cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Data(body.utf8))
    }
}
