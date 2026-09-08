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

/// Reads Claude limits only by asking Claude Code itself. This type has no
/// credential loader and cannot fall back to a keychain or bearer-token path.
actor ClaudeCLIOnlyProvider: UsageProvider {
    nonisolated let profile: ClaudeProfile
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.claude

    private let cli: ClaudeUsageCLI?

    init(profile: ClaudeProfile = .default()) {
        self.init(profile: profile, cli: ClaudeUsageCLI.locate())
    }

    init(profile: ClaudeProfile, cli: ClaudeUsageCLI?) {
        self.profile = profile
        self.id = profile.id
        self.displayName = profile.displayName
        self.cli = cli
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard let cli else { throw UsageProviderError.needsAuth }

        let windows: [LimitWindow]
        do {
            windows = try await cli.read(profile: profile)
        } catch {
            // There is deliberately no second source. A failed `/usage` read
            // means Claude Code itself needs attention.
            throw UsageProviderError.needsAuth
        }

        Log.usage.debug("claude: read \(windows.count) normalized windows from CLI")
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
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
