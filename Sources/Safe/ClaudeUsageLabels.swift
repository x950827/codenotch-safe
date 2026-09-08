import Foundation

/// Shared names and ordering for Claude Code's token-free `/usage` output.
enum ClaudeUsageLabels {
    static func label(forKind kind: String) -> String {
        switch kind {
        case "session":       return "Current session"
        case "weekly_all":    return "All models"
        case "weekly_opus":   return "Opus"
        case "weekly_sonnet": return "Sonnet"
        case "weekly_scoped", "scoped": return "Scoped"
        default:
            return kind
                .replacingOccurrences(of: "weekly_", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    static func displayOrder(_ a: LimitWindow, _ b: LimitWindow) -> Bool {
        func rank(_ id: String) -> Int {
            if id == "session" { return 0 }
            if id == "weekly_all" { return 1 }
            return 2
        }
        let (aRank, bRank) = (rank(a.id), rank(b.id))
        return aRank == bRank ? a.id < b.id : aRank < bRank
    }
}
