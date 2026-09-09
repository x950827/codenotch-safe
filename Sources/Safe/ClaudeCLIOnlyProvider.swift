import Foundation

/// The hardened build never auto-discovers `~/.claude-*` profiles. A named
/// profile may use an arbitrary API-key helper or provider configured outside
/// this repository; invoking it would execute that helper during a background
/// refresh. The default Claude Code login is the one audited path.
enum SafeClaudeProfiles {
    static func onlyDefault(
        home: URL = ClaudeProfile.homeDirectory
    ) -> [ClaudeProfile] {
        [.default(home: home)]
    }
}

/// Reads Claude limits from Claude Code's status-line feed, its own `/usage`
/// output, the narrowly audited OAuth usage reader, or dated local caches.
actor ClaudeCLIOnlyProvider: UsageProvider {
    nonisolated let profile: ClaudeProfile
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.claude

    private let cli: ClaudeUsageCLI?
    private let statusLineCache: SafeClaudeStatusLineCache?
    private let oauth: (@Sendable () async throws -> [LimitWindow])?
    private let cache: SafeClaudeUsageCache?

    init(profile: ClaudeProfile = .default()) {
        let oauth = SafeClaudeOAuthUsage(profile: profile)
        self.init(
            profile: profile,
            cli: ClaudeUsageCLI.locate(),
            statusLineCache: SafeClaudeStatusLineCache(profile: profile),
            oauth: { try await oauth.fetch() },
            cache: SafeClaudeUsageCache(profile: profile)
        )
    }

    init(profile: ClaudeProfile, cli: ClaudeUsageCLI?) {
        self.init(
            profile: profile,
            cli: cli,
            statusLineCache: SafeClaudeStatusLineCache(profile: profile),
            oauth: nil,
            cache: SafeClaudeUsageCache(profile: profile)
        )
    }

    init(
        profile: ClaudeProfile,
        cli: ClaudeUsageCLI?,
        statusLineCache: SafeClaudeStatusLineCache?,
        cache: SafeClaudeUsageCache?
    ) {
        self.init(
            profile: profile,
            cli: cli,
            statusLineCache: statusLineCache,
            oauth: nil,
            cache: cache
        )
    }

    init(
        profile: ClaudeProfile,
        cli: ClaudeUsageCLI?,
        statusLineCache: SafeClaudeStatusLineCache?,
        oauth: (@Sendable () async throws -> [LimitWindow])?,
        cache: SafeClaudeUsageCache?
    ) {
        self.profile = profile
        self.id = profile.id
        self.displayName = profile.displayName
        self.cli = cli
        self.statusLineCache = statusLineCache
        self.oauth = oauth
        self.cache = cache
    }

    init(profile: ClaudeProfile, cli: ClaudeUsageCLI?, cache: SafeClaudeUsageCache?) {
        self.init(profile: profile, cli: cli, statusLineCache: nil, cache: cache)
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let statusLineReading = try? statusLineCache?.read()
        if let reading = statusLineReading,
           Date().timeIntervalSince(reading.capturedAt) <= SafeClaudeStatusLineCache.freshFor {
            Log.usage.debug(
                "claude: read \(reading.windows.count) normalized windows from live status line"
            )
            return snapshot(windows: reading.windows, status: .ok)
        }

        if let cli {
            do {
                let windows = try await cli.read(profile: profile)
                Log.usage.debug("claude: read \(windows.count) normalized windows from CLI")
                return snapshot(windows: windows, status: .ok)
            } catch {
                // Recent Claude Code releases accept `/usage` in print mode but
                // emit only per-command cost statistics.
                Log.usage.debug("claude: CLI did not return usage windows; checking audited OAuth")
            }
        }

        var oauthError: Error?
        if let oauth {
            do {
                let windows = try await oauth()
                guard !windows.isEmpty else {
                    throw SafeClaudeOAuthBoundaryError.missingUsageWindows
                }
                return snapshot(windows: windows, status: .ok)
            } catch {
                oauthError = error
                Log.usage.debug("claude: audited OAuth unavailable; checking dated caches")
            }
        }

        if let reading = statusLineReading {
            Log.usage.debug(
                "claude: read \(reading.windows.count) normalized windows from dated status line"
            )
            return snapshot(
                windows: reading.windows,
                status: .stale(since: reading.capturedAt)
            )
        }

        if let cache, let reading = try? cache.read() {
            Log.usage.debug(
                "claude: read \(reading.windows.count) normalized windows from dated local cache"
            )
            return snapshot(
                windows: reading.windows,
                status: .stale(since: reading.fetchedAt)
            )
        }

        if let oauthError { throw oauthError }

        throw UsageProviderError.needsAuth
    }

    private func snapshot(
        windows: [LimitWindow],
        status: ProviderStatus
    ) -> ProviderSnapshot {
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: status,
            windows: windows,
            headlineID: "session"
        )
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance("Run `\(profile.signInCommand)` once, then use /login there to change account.")
    }

    nonisolated func account() -> ProviderAccount? {
        guard let address = profile.signedInAddress() else { return nil }
        return ProviderAccount(
            label: address,
            plan: nil,
            source: profile.sourceName,
            manageURL: URL(string: "https://claude.ai/settings/usage")
        )
    }
}
