import Foundation

/// Reads the normalized usage-only record written by the bundled Claude status
/// line bridge. The bridge receives rate limits from Claude Code itself, so the
/// app does not need a keychain token or a second Anthropic request.
struct SafeClaudeStatusLineCache: Sendable {
    struct Reading: Equatable, Sendable {
        let capturedAt: Date
        let windows: [LimitWindow]
    }

    static let freshFor: TimeInterval = 5 * 60

    private let data: @Sendable () throws -> Data

    init?(profile: ClaudeProfile) {
        guard profile.slug == nil else { return nil }
        let home = profile.configDirectory.deletingLastPathComponent()
        let file = ClaudeStatusLineRecord.defaultCacheURL(home: home)
        self.init(data: { try Data(contentsOf: file) })
    }

    init(data: @escaping @Sendable () throws -> Data) {
        self.data = data
    }

    func read(now: Date = Date()) throws -> Reading {
        let record = try JSONDecoder().decode(ClaudeStatusLineRecord.self, from: data())
        guard record.schemaVersion == 1,
              record.capturedAtMs.isFinite,
              record.capturedAtMs > 0,
              record.capturedAt <= now.addingTimeInterval(60)
        else { throw UsageProviderError.badResponse(status: 0) }

        let candidates: [(String, ClaudeStatusLineRecord.Window?)] = [
            ("session", record.fiveHour),
            ("weekly_all", record.sevenDay),
            ("weekly_opus", record.sevenDayOpus),
            ("weekly_sonnet", record.sevenDaySonnet),
        ]
        let windows = candidates.compactMap { kind, entry -> LimitWindow? in
            guard let entry,
                  entry.usedPercentage.isFinite,
                  (0 ... 100).contains(entry.usedPercentage)
            else { return nil }
            let resetsAt = entry.resetsAtEpochSeconds.flatMap { seconds -> Date? in
                guard seconds.isFinite, seconds > now.timeIntervalSince1970 else { return nil }
                return Date(timeIntervalSince1970: seconds)
            }
            // An expired session belongs to the previous five-hour block. It
            // must disappear instead of looking current after the reset.
            if kind == "session", entry.resetsAtEpochSeconds != nil, resetsAt == nil {
                return nil
            }
            return LimitWindow(
                id: kind,
                label: ClaudeUsageLabels.label(forKind: kind),
                usedFraction: entry.usedPercentage / 100,
                resetsAt: resetsAt
            )
        }.sorted(by: ClaudeUsageLabels.displayOrder)

        guard windows.contains(where: { $0.id == "session" }) else {
            throw UsageProviderError.badResponse(status: 0)
        }
        return Reading(capturedAt: record.capturedAt, windows: windows)
    }
}
