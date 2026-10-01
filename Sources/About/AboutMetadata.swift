import Foundation

enum AboutMetadata {
    static let originalAuthor = "Vinz"
    static let copyright = "Copyright (c) 2026 Vinz"
    static let attribution = "Codenotch Safe is based on Codenotch by Vinz."
    static let accountAccessExplanation = "Codenotch Safe reads limits from local integrations already used by Claude and Codex. Cursor and OpenCode may contact their respective usage endpoints when enabled. A disabled provider is not queried and its activity monitor is stopped."

    static let originalSourceURL = URL(string: "https://github.com/vinzdg/codenotch")!
    static let safeSourceURL = URL(string: "https://github.com/x950827/codenotch-safe")!
    static let auditURL = URL(
        string: "https://github.com/x950827/codenotch-safe/blob/main/SECURITY-AUDIT.md"
    )!
    static let licenseURL = URL(
        string: "https://github.com/vinzdg/codenotch/blob/main/LICENSE"
    )!

    static let safeChanges = [
        "Claude limits use local Claude Code integrations without Keychain or bearer-token reads.",
        "Codex limits use its local app server without bearer-token reads.",
        "Cursor and OpenCode are the only providers allowed to contact their audited usage endpoints, and only while enabled; OpenCode reads the opencode-go key from the user's own auth.json without Keychain or bearer-token reads from elsewhere.",
        "The Safe build has no embedded web view, updater, or analytics; CI checks its credential and network boundaries.",
    ]
}
