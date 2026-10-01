import Foundation

/// Reads OpenCode Go plan usage from the official endpoint, with the key
/// OpenCode itself stores on sign-in — see `OpenCodeCredentials`.
///
/// The numbers are OpenCode's, so this is `.official`. The endpoint throttles,
/// so a 429 backs off on a schedule that outlives the process rather than
/// polling into the limit, and every failure degrades to a status the UI can
/// render honestly.
///
/// Two upstream quirks worth knowing, both commented where they bite: a valid
/// key with no Go plan answers 401, the same as a bad key; and the
/// pay-as-you-go Zen balance has no API at all, so this covers the Go windows
/// only.
///
/// The session is ephemeral and refuses redirects — the same shape as
/// `CursorSafeProvider` — so a misconfigured endpoint cannot follow the
/// request somewhere it is not allowed to go.
actor OpenCodeSafeProvider: UsageProvider {
    nonisolated let id = "opencode"
    nonisolated let displayName = "OpenCode"
    nonisolated let glyph = ProviderGlyph.opencode

    private let redirectDelegate: RedirectRejectingSessionDelegate?
    private let session: URLSession
    private let loadCredentials: @Sendable () throws -> OpenCodeCredentials.Credential
    private let archive: UsageArchive
    /// Set when the endpoint returns 429. Until it passes, refreshes are
    /// skipped without touching the network — the same bargain Claude's makes.
    private var retryNoEarlierThan: Date?
    private var consecutiveRateLimits = 0

    init(
        session: URLSession? = nil,
        loadCredentials: @escaping @Sendable () throws -> OpenCodeCredentials.Credential = {
            guard let credential = OpenCodeCredentials.load() else {
                throw UsageProviderError.needsAuth
            }
            return credential
        },
        archive: UsageArchive = UsageArchive()
    ) {
        if let session {
            self.redirectDelegate = nil
            self.session = session
        } else {
            let delegate = RedirectRejectingSessionDelegate()
            self.redirectDelegate = delegate
            self.session = URLSession(
                configuration: OpenCodeEndpoint.makeConfiguration(),
                delegate: delegate,
                delegateQueue: nil
            )
        }
        self.loadCredentials = loadCredentials
        self.archive = archive
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: id)
    }

    deinit {
        session.invalidateAndCancel()
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance("Usage rides on the opencode-go key OpenCode stores on sign-in — "
                  + "connect Go inside OpenCode (`opencode auth login`) and the notch reads it.")
    }

    nonisolated func account() -> ProviderAccount? {
        // Mirrors `CursorSafeProvider.account()` — show the row only when the
        // credential is readable, so a disconnected provider does not display
        // an account it cannot read.
        guard (try? loadCredentials()) != nil else { return nil }
        return ProviderAccount(
            label: nil,
            plan: "Go",
            source: "OpenCode",
            manageURL: URL(string: "https://opencode.ai")
        )
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let retryNoEarlierThan, retryNoEarlierThan > Date() {
            let remaining = retryNoEarlierThan.timeIntervalSinceNow
            Log.usage.debug("opencode: skipping fetch, backing off for \(remaining, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: remaining)
        }

        // Re-read on every fetch. This is an ordinary file, not a keychain
        // item: reading it puts no prompt in front of anyone.
        let credentials: OpenCodeCredentials.Credential
        do {
            credentials = try loadCredentials()
        } catch {
            throw UsageProviderError.needsAuth
        }

        let request: URLRequest
        do {
            request = try OpenCodeEndpoint.makeRequest(token: credentials.token)
        } catch {
            throw UsageProviderError.needsAuth
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageProviderError.badResponse(status: 0)
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard let responseURL = http?.url, OpenCodeEndpoint.isAllowed(responseURL) else {
            // A redirect or a host change is not a successful request, even
            // if the status code looks healthy.
            throw OpenCodeBoundaryError.invalidEndpoint
        }
        // The production session uses `RedirectRejectingSessionDelegate` to
        // cancel redirects; if a 3xx still surfaces here the server is not
        // playing along with the allowlist, so reject it the same way.
        if (300..<400).contains(status) {
            throw OpenCodeBoundaryError.invalidEndpoint
        }

        Log.usage.debug("opencode: status \(status)")

        // Upstream serves a missing Go plan as 401 through the same branch as
        // a bad key. Both read as "nothing readable here", and the settings
        // row says how to connect.
        if status == 401 { throw UsageProviderError.needsAuth }
        // A valid key that is not entitled to Go: readable, but metering
        // nothing — not an error, and it must not be shown as one.
        if status == 403 { throw UsageProviderError.nothingMetered("No OpenCode Go subscription on this key") }
        if status == 429 {
            let wait = OpenCodeEndpoint.backoff(
                forAttempt: consecutiveRateLimits,
                retryAfter: OpenCodeEndpoint.retryAfter(from: response)
            )
            consecutiveRateLimits += 1
            let until = Date().addingTimeInterval(wait)
            retryNoEarlierThan = until
            archive.saveBackoffUntil(until, providerID: id)
            Log.usage.notice("opencode: rate limited (\(self.consecutiveRateLimits)x), next attempt in \(wait, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: wait)
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw UsageProviderError.badResponse(status: 0)
        }

        let windows = try OpenCodeUsage.windows(fromJSON: body)

        consecutiveRateLimits = 0
        retryNoEarlierThan = nil
        archive.saveBackoffUntil(nil, providerID: id)

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: windows,
            headlineID: "rolling"
        )
    }
}
