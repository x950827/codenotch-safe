import Foundation
import SQLite3

/// The OpenCode Go key, borrowed from OpenCode's own sign-in.
///
/// OpenCode v2 stores the active console key in `opencode.db`. Earlier
/// versions keep the Go key in `auth.json`. Both stores are read-only;
/// OAuth access tokens and other vendors' credentials are never selected.
///
/// `~/.local/share/opencode/auth.json` holds one entry per connected account.
/// The `opencode-go` entry (`{"type": "api", "key": ...}`) is the Go plan's API
/// key, and it authenticates the usage endpoint directly — no workspace id, no
/// cookie, no second sign-in. Any other entry (`openai`, `google`, …) is that
/// vendor's key, and claiming one would read the wrong account under
/// OpenCode's name.
enum OpenCodeCredentials {
    struct Credential {
        let token: String
    }

    static var authURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/share/opencode/auth.json")
    }

    static func load(from url: URL = authURL) -> Credential? {
        let databaseURL = url.deletingLastPathComponent().appendingPathComponent("opencode.db")
        if let credential = loadDatabase(from: databaseURL) { return credential }
        return loadLegacy(from: url)
    }

    private static func loadDatabase(from url: URL) -> Credential? {
        guard let db = SQLiteStore.open(url) else { return nil }
        defer { sqlite3_close(db) }
        let rows = SQLiteStore.rows(
            in: db,
            sql: "SELECT value FROM credential WHERE integration_id IN ('opencode', 'opencode-go') AND active = 1"
        )
        // An ambiguous selection must never borrow a key from an arbitrary account.
        guard rows.count == 1,
              let data = rows[0].data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "key",
              let token = nonEmpty(object["key"] as? String)
        else { return nil }
        return Credential(token: token)
    }

    private static func loadLegacy(from url: URL) -> Credential? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["opencode-go"]
        else { return nil }
        // The entry is either the key itself or an object carrying it — both
        // shapes have shipped across OpenCode versions.
        if let token = nonEmpty(entry as? String) { return Credential(token: token) }
        guard let object = entry as? [String: Any] else { return nil }
        let token = ["key", "apiKey", "api_key", "token", "accessToken"]
            .compactMap { nonEmpty(object[$0] as? String) }.first
        return token.map(Credential.init(token:))
    }

    /// Non-empty strings only: an empty key is worse than a missing one, it is
    /// a request that cannot succeed being sent all the same.
    private static func nonEmpty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }
}
