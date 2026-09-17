import Foundation

/// The complete subset of Claude's status-line input Codenotch is allowed to
/// retain. Claude also supplies the current session, transcript path, model,
/// workspace and token counts; none of those fields are declared here and none
/// survive `capture`.
struct ClaudeStatusLineRecord: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        let usedPercentage: Double
        let resetsAtEpochSeconds: Double?
    }

    let schemaVersion: Int
    let capturedAtMs: Double
    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOpus: Window?
    let sevenDaySonnet: Window?

    var capturedAt: Date {
        Date(timeIntervalSince1970: capturedAtMs / 1_000)
    }

    static func capture(_ data: Data, capturedAt: Date = Date()) throws -> Self {
        let input = try JSONDecoder().decode(StatusLineInput.self, from: data)
        guard let limits = input.rateLimits else {
            throw CaptureError.missingSessionWindow
        }

        let record = Self(
            schemaVersion: 1,
            capturedAtMs: capturedAt.timeIntervalSince1970 * 1_000,
            fiveHour: normalized(limits.fiveHour),
            sevenDay: normalized(limits.sevenDay),
            sevenDayOpus: normalized(limits.sevenDayOpus),
            sevenDaySonnet: normalized(limits.sevenDaySonnet)
        )
        guard record.fiveHour != nil else {
            throw CaptureError.missingSessionWindow
        }
        if let reset = record.fiveHour?.resetsAtEpochSeconds,
           reset <= capturedAt.timeIntervalSince1970 {
            throw CaptureError.expiredSessionWindow
        }
        return record
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func defaultCacheURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent("local.audited.codenotch", isDirectory: true)
            .appendingPathComponent("claude-statusline-usage.json")
    }

    private static func normalized(_ window: InputWindow?) -> Window? {
        guard let percent = window?.usedPercentage?.value,
              percent.isFinite,
              (0 ... 100).contains(percent)
        else { return nil }

        let reset = (window?.resetsAt?.value).flatMap { value -> Double? in
            guard value.isFinite, value > 0 else { return nil }
            return value
        }
        return Window(usedPercentage: percent, resetsAtEpochSeconds: reset)
    }

    private struct StatusLineInput: Decodable {
        let rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case rateLimits = "rate_limits"
        }
    }

    private struct RateLimits: Decodable {
        let fiveHour: InputWindow?
        let sevenDay: InputWindow?
        let sevenDayOpus: InputWindow?
        let sevenDaySonnet: InputWindow?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
        }
    }

    private struct InputWindow: Decodable {
        let usedPercentage: CoercedDouble?
        let resetsAt: CoercedDouble?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }

    /// Claude Code has emitted status-line numeric fields as both JSON numbers
    /// and numeric strings. Match its documented consumer behavior while still
    /// rejecting empty, non-numeric and non-finite values.
    private struct CoercedDouble: Decodable {
        let value: Double

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self), number.isFinite {
                value = number
                return
            }
            if let text = try? container.decode(String.self) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let number = Double(trimmed), number.isFinite {
                    value = number
                    return
                }
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "expected a finite number or numeric string"
            )
        }
    }

    private enum CaptureError: Error {
        case missingSessionWindow
        case expiredSessionWindow
    }
}
