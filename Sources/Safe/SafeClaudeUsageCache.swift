import Foundation

/// Claude Code keeps the last usage response in its ordinary settings file so
/// its own UI can reopen without briefly showing empty limits. The hardened app
/// may use that vendor-written cache when print mode no longer renders `/usage`.
///
/// Decoding is deliberately narrow: the document also contains account and
/// configuration data, but this type declares only the timestamp and four known
/// usage windows. Unknown keys are ignored by `JSONDecoder` and never enter a
/// value Codenotch can retain or log.
struct SafeClaudeUsageCache: Sendable {
    struct Reading: Equatable, Sendable {
        let fetchedAt: Date
        let windows: [LimitWindow]
    }

    private let data: @Sendable () throws -> Data

    /// Only the default Claude Code profile is part of the safe build. Its
    /// settings file is `~/.claude.json`; named configuration directories can
    /// contain arbitrary user-managed profile behavior and are rejected here
    /// even if this type is constructed outside `SafeClaudeProfiles`.
    init?(profile: ClaudeProfile) {
        guard profile.slug == nil else { return nil }
        let file = profile.accountFileURL
        self.init(data: { try Data(contentsOf: file) })
    }

    /// Injection point for a fixture. The closure returns bytes only; parsing
    /// and field selection stay inside the production implementation.
    init(data: @escaping @Sendable () throws -> Data) {
        self.data = data
    }

    func read() throws -> Reading {
        try Self.parse(data())
    }

    static func parse(_ data: Data) throws -> Reading {
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard let cache = document.cachedUsageUtilization,
              let fetchedAtMs = cache.fetchedAtMs,
              fetchedAtMs.isFinite,
              fetchedAtMs > 0,
              let utilization = cache.utilization
        else { throw UsageProviderError.badResponse(status: 0) }

        let candidates: [(String, Entry?)] = [
            ("session", utilization.fiveHour),
            ("weekly_all", utilization.sevenDay),
            ("weekly_opus", utilization.sevenDayOpus),
            ("weekly_sonnet", utilization.sevenDaySonnet),
        ]
        let windows = candidates.compactMap { kind, entry -> LimitWindow? in
            guard let percent = entry?.utilization,
                  percent.isFinite,
                  percent >= 0
            else { return nil }
            return LimitWindow(
                id: kind,
                label: ClaudeUsageLabels.label(forKind: kind),
                usedFraction: percent / 100,
                resetsAt: entry?.resetsAt.flatMap(resetDate)
            )
        }.sorted(by: ClaudeUsageLabels.displayOrder)

        guard windows.contains(where: { $0.id == "session" }) else {
            throw UsageProviderError.badResponse(status: 0)
        }
        return Reading(
            fetchedAt: Date(timeIntervalSince1970: fetchedAtMs / 1_000),
            windows: windows
        )
    }

    private static func resetDate(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private struct Document: Decodable {
        let cachedUsageUtilization: CachedUsage?
    }

    private struct CachedUsage: Decodable {
        let fetchedAtMs: Double?
        let utilization: Utilization?
    }

    private struct Utilization: Decodable {
        let fiveHour: Entry?
        let sevenDay: Entry?
        let sevenDayOpus: Entry?
        let sevenDaySonnet: Entry?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
        }
    }

    private struct Entry: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
}
