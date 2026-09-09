import CryptoKit
import Foundation
import Security

enum SafeClaudeOAuthBoundaryError: Error {
    case invalidCredential
    case invalidEndpoint
    case missingUsageWindows
}

/// The only credential-bearing Claude path in the hardened build.
///
/// It reads the newest Claude Code login item, keeps the access token only in
/// memory until it expires, and sends it in one GET to Anthropic's exact usage
/// endpoint. Redirects, cookies, URL credentials, caches, proxies and token
/// refreshes are all disabled. Only normalized usage windows leave this type.
actor SafeClaudeOAuthUsage {
    struct Credential: Sendable, Equatable {
        let accessToken: String
        let expiresAt: Date
    }

    private struct KeychainMatch {
        let modifiedAt: Date?
        let persistentReference: Data
    }

    private static let endpoint = URL(
        string: "https://api.anthropic.com/api/oauth/usage"
    )!
    private static let bareCredentialService = "Claude Code-credentials"

    private let redirectDelegate: RedirectRejectingSessionDelegate?
    private let session: URLSession
    private let loadCredential: @Sendable () throws -> Credential
    private var cachedCredential: Credential?
    private var retryNoEarlierThan: Date?

    init(
        profile: ClaudeProfile = .default(),
        session: URLSession? = nil,
        loadCredential: (@Sendable () throws -> Credential)? = nil
    ) {
        let services = Self.credentialServices(profile: profile)
        self.loadCredential = loadCredential ?? {
            try Self.readCredential(services: services)
        }

        if let session {
            self.redirectDelegate = nil
            self.session = session
        } else {
            let delegate = RedirectRejectingSessionDelegate()
            self.redirectDelegate = delegate
            self.session = URLSession(
                configuration: Self.makeConfiguration(),
                delegate: delegate,
                delegateQueue: nil
            )
        }
    }

    deinit {
        session.invalidateAndCancel()
    }

    func fetch() async throws -> [LimitWindow] {
        if let retryNoEarlierThan, retryNoEarlierThan > Date() {
            throw UsageProviderError.rateLimited(
                retryAfter: retryNoEarlierThan.timeIntervalSinceNow
            )
        }

        let credential = try currentCredential()
        let request = try Self.makeRequest(token: credential.accessToken)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let responseURL = http.url,
              Self.isAllowed(responseURL)
        else {
            throw SafeClaudeOAuthBoundaryError.invalidEndpoint
        }

        switch http.statusCode {
        case 200..<300:
            retryNoEarlierThan = nil
        case 401, 403:
            cachedCredential = nil
            throw UsageProviderError.needsAuth
        case 429:
            let retryAfter: TimeInterval = 5 * 60
            retryNoEarlierThan = Date().addingTimeInterval(retryAfter)
            throw UsageProviderError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageProviderError.badResponse(status: http.statusCode)
        }

        let windows = try Self.parse(data)
        guard !windows.isEmpty else {
            throw SafeClaudeOAuthBoundaryError.missingUsageWindows
        }
        Log.usage.debug(
            "claude: OAuth usage endpoint returned \(windows.count) normalized windows"
        )
        return windows
    }

    private func currentCredential() throws -> Credential {
        if let cachedCredential, cachedCredential.expiresAt > Date() {
            return cachedCredential
        }
        let credential = try loadCredential()
        guard credential.expiresAt > Date() else {
            throw UsageProviderError.credentialExpired
        }
        cachedCredential = credential
        return credential
    }

    static func makeRequest(token: String) throws -> URLRequest {
        guard !token.isEmpty,
              !token.contains("\r"),
              !token.contains("\n")
        else {
            throw SafeClaudeOAuthBoundaryError.invalidCredential
        }

        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return request
    }

    static func parse(_ data: Data) throws -> [LimitWindow] {
        struct Response: Decodable {
            struct Window: Decodable {
                let utilization: Double
                let resetsAt: String?

                private enum CodingKeys: String, CodingKey {
                    case utilization
                    case resetsAt = "resets_at"
                }
            }

            let fiveHour: Window?
            let sevenDay: Window?

            private enum CodingKeys: String, CodingKey {
                case fiveHour = "five_hour"
                case sevenDay = "seven_day"
            }
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        var windows: [LimitWindow] = []

        func append(
            _ window: Response.Window?,
            id: String,
            label: String
        ) throws {
            guard let window else { return }
            guard window.utilization.isFinite, window.utilization >= 0 else {
                throw SafeClaudeOAuthBoundaryError.missingUsageWindows
            }
            windows.append(LimitWindow(
                id: id,
                label: label,
                usedFraction: window.utilization / 100,
                resetsAt: window.resetsAt.flatMap(parseDate)
            ))
        }

        try append(response.fiveHour, id: "session", label: "Current session")
        try append(response.sevenDay, id: "weekly_all", label: "All models")
        return windows
    }

    static func parseCredential(_ data: Data) throws -> Credential {
        struct Payload: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                let expiresAt: Double
            }
            let claudeAiOauth: OAuth
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let token = payload.claudeAiOauth.accessToken
        let milliseconds = payload.claudeAiOauth.expiresAt
        guard !token.isEmpty,
              !token.contains("\r"),
              !token.contains("\n"),
              milliseconds.isFinite,
              milliseconds > 0
        else {
            throw SafeClaudeOAuthBoundaryError.invalidCredential
        }
        return Credential(
            accessToken: token,
            expiresAt: Date(timeIntervalSince1970: milliseconds / 1_000)
        )
    }

    static func credentialServices(configDirectory: URL) -> [String] {
        let path = (configDirectory.path as NSString).standardizingPath
        let digest = SHA256.hash(data: Data(path.utf8))
        let suffix = digest.prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
        return ["\(bareCredentialService)-\(suffix)", bareCredentialService]
    }

    static func credentialServices(profile: ClaudeProfile) -> [String] {
        let candidates = credentialServices(
            configDirectory: profile.configDirectory
        )
        return profile.slug == nil ? candidates : [candidates[0]]
    }

    private static func readCredential(services: [String]) throws -> Credential {
        let matches = services.flatMap(matches(service:))
        guard let newest = matches.max(by: {
            ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast)
        }) else {
            throw UsageProviderError.needsAuth
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecValuePersistentRef: newest.persistentReference,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status == errSecInteractionNotAllowed
                || status == errSecUserCanceled
                || status == errSecAuthFailed {
                throw UsageProviderError.accessDenied
            }
            throw UsageProviderError.needsAuth
        }
        return try parseCredential(data)
    }

    private static func matches(service: String) -> [KeychainMatch] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecReturnPersistentRef: true,
            kSecMatchLimit: kSecMatchLimitAll
        ] as CFDictionary, &result)
        guard status == errSecSuccess else { return [] }

        let dictionaries = (result as? [[CFString: Any]])
            ?? (result as? [CFString: Any]).map { [$0] }
            ?? []
        return dictionaries.compactMap { item in
            guard let reference = item[kSecValuePersistentRef] as? Data else {
                return nil
            }
            return KeychainMatch(
                modifiedAt: item[kSecAttrModificationDate] as? Date,
                persistentReference: reference
            )
        }
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
        guard let components = URLComponents(
            url: target,
            resolvingAgainstBaseURL: false
        ) else {
            return false
        }
        return components.scheme == "https"
            && components.host == "api.anthropic.com"
            && components.port == nil
            && components.user == nil
            && components.password == nil
            && components.percentEncodedPath == "/api/oauth/usage"
            && components.percentEncodedQuery == nil
            && components.fragment == nil
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
