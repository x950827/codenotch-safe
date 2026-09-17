import Foundation
import SQLite3

/// The two values Cursor's editor stores for its own authenticated session.
/// This loader has no Keychain or cursor-agent fallback.
struct CursorEditorCredentials: Sendable {
    let accountID: String
    let accessToken: String

    var cookieValue: String { "\(accountID)::\(accessToken)" }

    static var storeURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    static let bundleID = "com.todesktop.230313mzl4w4u92"

    static func load(from url: URL = storeURL) throws -> CursorEditorCredentials {
        guard let db = SQLiteStore.open(url) else { throw UsageProviderError.needsAuth }
        defer { sqlite3_close(db) }

        func value(_ key: String) -> String? {
            SQLiteStore.rows(
                in: db,
                sql: "SELECT value FROM ItemTable WHERE key = ?",
                bind: key
            ).first?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let accessToken = value("cursorAuth/accessToken"), !accessToken.isEmpty,
              let accountID = value("cursorAuth/stripeMembershipAuthId"), !accountID.isEmpty
        else { throw UsageProviderError.needsAuth }

        return CursorEditorCredentials(accountID: accountID, accessToken: accessToken)
    }

    static func account(from url: URL = storeURL) -> ProviderAccount? {
        guard let db = SQLiteStore.open(url) else { return nil }
        defer { sqlite3_close(db) }

        func value(_ key: String) -> String? {
            SQLiteStore.rows(
                in: db,
                sql: "SELECT value FROM ItemTable WHERE key = ?",
                bind: key
            ).first
        }
        guard let email = value("cursorAuth/cachedEmail"), !email.isEmpty else { return nil }
        return ProviderAccount(
            label: email,
            plan: value("cursorAuth/stripeMembershipType"),
            source: "Cursor",
            manageURL: URL(string: "https://cursor.com/dashboard")
        )
    }
}
