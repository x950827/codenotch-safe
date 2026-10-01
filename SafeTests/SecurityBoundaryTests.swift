import Combine
import Foundation
import SQLite3
import XCTest
@testable import Codenotch

final class SecurityBoundaryTests: XCTestCase {
    @MainActor
    func testFiveMinuteTimerDoesNotSkipForSubsecondClockSkew() {
        XCTAssertFalse(UsageStore.shouldRefresh(
            isBusy: false,
            sinceLastAttempt: 298.9,
            idleInterval: 300
        ))
        XCTAssertTrue(UsageStore.shouldRefresh(
            isBusy: false,
            sinceLastAttempt: 299.5,
            idleInterval: 300
        ))
    }

    func testCodexHandshakeRequestsOnlyRateLimits() throws {
        let messages = try CodexAppServerProtocol.input
            .split(separator: "\n")
            .map { line -> [String: Any] in
                try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                )
            }

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages.compactMap { $0["method"] as? String }, [
            "initialize",
            "initialized",
            "account/rateLimits/read",
        ])
        XCTAssertEqual(messages[0]["id"] as? Int, 0)
        XCTAssertNil(messages[1]["id"])
        XCTAssertEqual(messages[2]["id"] as? Int, 1)

        let clientInfo = try XCTUnwrap(
            (messages[0]["params"] as? [String: Any])?["clientInfo"] as? [String: Any]
        )
        XCTAssertEqual(Set(clientInfo.keys), ["name", "title", "version"])
        XCTAssertEqual(clientInfo["name"] as? String, "codenotch_safe_local")
        XCTAssertNil(messages[2]["params"])
    }

    func testCodexHandshakeKeepsInputOpenUntilTheRateLimitResponse() throws {
        var events: [String] = []
        var replies = [
            #"{"id":0,"result":{"userAgent":"test"}}"#,
            #"{"method":"remoteControl/status/changed","params":{}}"#,
            #"{"id":1,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}}}"#,
        ]

        let windows = try CodexAppServerProtocol.exchange(
            send: { message in
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
                )
                events.append("send:\(try XCTUnwrap(object["method"] as? String))")
            },
            receive: {
                events.append("receive")
                return replies.isEmpty ? nil : replies.removeFirst()
            },
            closeInput: {
                events.append("close")
            }
        )

        XCTAssertEqual(events, [
            "send:initialize",
            "receive",
            "send:initialized",
            "send:account/rateLimits/read",
            "receive",
            "receive",
            "close",
        ])
        XCTAssertEqual(windows.first?.usedFraction, 0.25)
    }

    func testCodexParserSelectsOnlyResponseOneAndPrefersCodexBucket() throws {
        let output = """
        {"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":99}}}}
        {"id":0,"result":{"userAgent":"ignored"}}
        {"id":1,"result":{"rateLimits":{"limitId":"legacy","primary":{"usedPercent":88,"windowDurationMins":60}},"rateLimitsByLimitId":{"other":{"limitId":"other","primary":{"usedPercent":77,"windowDurationMins":120}},"codex":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800000100},"secondary":{"usedPercent":18,"windowDurationMins":10080,"resetsAt":1800600000}}}}}
        {"id":7,"result":{"rateLimits":{"primary":{"usedPercent":66}}}}
        """

        let windows = try CodexAppServerProtocol.parse(output)

        XCTAssertEqual(windows.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(windows.map(\.label), ["5h limit", "Weekly limit"])
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(windows[1].usedFraction ?? -1, 0.18, accuracy: 0.0001)
        XCTAssertEqual(windows[0].resetsAt, Date(timeIntervalSince1970: 1_800_000_100))
    }

    func testCodexParserRefusesMissingAndErrorResponses() {
        XCTAssertThrowsError(try CodexAppServerProtocol.parse(
            #"{"id":0,"result":{}}"#
        ))
        XCTAssertThrowsError(try CodexAppServerProtocol.parse(
            #"{"id":1,"error":{"code":-32001,"message":"authentication required"}}"#
        ))
    }

    func testCodexExecutableUsesOnlyTheAppServerSubcommand() {
        XCTAssertEqual(CodexAppServerExecutable.arguments, ["app-server"])
    }

    func testCodexExecutablePrefersTheBundledChatGPTBinaryOverUserWrappers() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("codenotch-codex-locator-\(UUID().uuidString)")
        let home = sandbox.appendingPathComponent("home")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let bundled = sandbox
            .appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex")
        let wrapper = home.appendingPathComponent(".local/bin/codex")
        for candidate in [bundled, wrapper] {
            try FileManager.default.createDirectory(
                at: candidate.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\n".utf8).write(to: candidate)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: candidate.path
            )
        }

        let executable = try XCTUnwrap(CodexAppServerExecutable.locate(
            home: home,
            root: sandbox
        ))

        XCTAssertEqual(executable.binary.standardizedFileURL,
                       bundled.standardizedFileURL)
    }

    func testCodexProviderUsesInjectedAppServerReader() async throws {
        let provider = CodexAppServerProvider(readWindows: {
            [LimitWindow(id: "primary", label: "5h limit", usedFraction: 0.21)]
        })

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.id, "codex")
        XCTAssertEqual(snapshot.windows.first?.usedFraction, 0.21)
        XCTAssertEqual(snapshot.headlineID, "primary")
        XCTAssertNil(provider.account())
    }

    func testClaudeLabelsDoNotDependOnOAuthResponseTypes() {
        XCTAssertEqual(ClaudeUsageLabels.label(forKind: "session"), "Current session")
        XCTAssertEqual(ClaudeUsageLabels.label(forKind: "weekly_all"), "All models")
        XCTAssertEqual(ClaudeUsageLabels.label(forKind: "weekly_opus"), "Opus")

        let weekly = LimitWindow(id: "weekly_all", label: "All models")
        let session = LimitWindow(id: "session", label: "Current session")
        XCTAssertTrue(ClaudeUsageLabels.displayOrder(session, weekly))
    }

    func testClaudeInvocationDisablesCustomizationToolsAndPersistence() {
        XCTAssertEqual(ClaudeUsageCLI.arguments, [
            "--print",
            "--safe-mode",
            "--strict-mcp-config",
            "--tools", "",
            "--no-chrome",
            "--no-session-persistence",
            "/usage",
        ])
    }

    func testSafeClaudePolicyUsesOnlyTheDefaultProfile() {
        let home = URL(fileURLWithPath: "/tmp/codenotch-safe-home")

        XCTAssertEqual(
            SafeClaudeProfiles.onlyDefault(home: home),
            [ClaudeProfile.default(home: home)]
        )
    }

    func testClaudeEnvironmentRejectsCredentialEndpointAndProxyOverrides() {
        let profile = ClaudeProfile(
            slug: "work",
            configDirectory: URL(fileURLWithPath: "/tmp/.claude-work")
        )
        let environment = ClaudeUsageCLI.sanitizedEnvironment(
            profile: profile,
            source: [
                "HOME": "/tmp/home",
                "PATH": "/usr/bin:/bin",
                "LANG": "en_US.UTF-8",
                "ANTHROPIC_API_KEY": "must-not-pass",
                "ANTHROPIC_BASE_URL": "https://must-not-pass.example",
                "HTTP_PROXY": "http://must-not-pass.example",
                "CLAUDE_CONFIG_DIR": "/tmp/wrong-profile",
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            ]
        )

        XCTAssertEqual(environment["HOME"], "/tmp/home")
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/tmp/.claude-work")
        XCTAssertNil(environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"])
        XCTAssertEqual(environment["DISABLE_AUTOUPDATER"], "1")
        XCTAssertEqual(environment["DISABLE_TELEMETRY"], "1")
        XCTAssertEqual(environment["DISABLE_ERROR_REPORTING"], "1")
        XCTAssertEqual(environment["DISABLE_FEEDBACK_COMMAND"], "1")
        XCTAssertEqual(environment["ENABLE_CLAUDEAI_MCP_SERVERS"], "false")
        XCTAssertEqual(environment["CLAUDE_CODE_DISABLE_ARTIFACT"], "1")
        XCTAssertEqual(environment["CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL"], "1")
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["ANTHROPIC_BASE_URL"])
        XCTAssertNil(environment["HTTP_PROXY"])
    }

    func testClaudeCacheParsesOnlyKnownUsageWindows() throws {
        let json = #"""
        {
          "cachedUsageUtilization": {
            "accountUuid": "must-not-be-read",
            "fetchedAtMs": 1800000000123,
            "utilization": {
              "five_hour": {
                "utilization": 43,
                "resets_at": "2027-01-15T12:30:00.250000+00:00",
                "locked_reason": "ignored"
              },
              "seven_day": {
                "utilization": 16,
                "resets_at": "2027-01-18T08:00:00+00:00"
              },
              "seven_day_opus": null,
              "seven_day_sonnet": {"utilization": 7},
              "unknown_limit": {"utilization": 99, "secret": "ignored"}
            }
          }
        }
        """#

        let reading = try SafeClaudeUsageCache.parse(Data(json.utf8))

        XCTAssertEqual(reading.fetchedAt,
                       Date(timeIntervalSince1970: 1_800_000_000.123))
        XCTAssertEqual(reading.windows.map(\.id), [
            "session", "weekly_all", "weekly_sonnet",
        ])
        XCTAssertEqual(reading.windows.map(\.label), [
            "Current session", "All models", "Sonnet",
        ])
        XCTAssertEqual(reading.windows.map(\.usedFraction), [0.43, 0.16, 0.07])
        XCTAssertEqual(reading.windows[0].resetsAt,
                       Date(timeIntervalSince1970: 1_800_016_200.25))
        XCTAssertEqual(reading.windows[1].resetsAt,
                       Date(timeIntervalSince1970: 1_800_259_200))
    }

    func testClaudeCacheRejectsMissingOrMalformedSessionUsage() {
        let missing = #"{"cachedUsageUtilization":{"fetchedAtMs":1800000000000,"utilization":{"seven_day":{"utilization":10}}}}"#
        let malformed = #"{"cachedUsageUtilization":{"fetchedAtMs":1800000000000,"utilization":{"five_hour":{"utilization":"secret"}}}}"#

        XCTAssertThrowsError(try SafeClaudeUsageCache.parse(Data(missing.utf8)))
        XCTAssertThrowsError(try SafeClaudeUsageCache.parse(Data(malformed.utf8)))
    }

    func testClaudeCacheRejectsAnExpiredSessionWindow() {
        let expired = #"{"cachedUsageUtilization":{"fetchedAtMs":946684800000,"utilization":{"five_hour":{"utilization":12,"resets_at":"2000-01-01T00:00:00Z"},"seven_day":{"utilization":16,"resets_at":"2100-01-01T00:00:00Z"}}}}"#

        XCTAssertThrowsError(try SafeClaudeUsageCache.parse(Data(expired.utf8)))
    }

    func testClaudeStatusLineCaptureKeepsOnlyNormalizedRateLimits() throws {
        let input = #"""
        {
          "session_id": "must-not-be-stored",
          "transcript_path": "/private/must-not-be-stored.jsonl",
          "account": {"token": "must-not-be-stored"},
          "rate_limits": {
            "five_hour": {
              "used_percentage": "11",
              "resets_at": "1800016200.25",
              "secret": "must-not-be-stored"
            },
            "seven_day": {"used_percentage": 18, "resets_at": 1800259200},
            "seven_day_opus": null,
            "seven_day_sonnet": {"used_percentage": 7}
          }
        }
        """#
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000.123)

        let record = try ClaudeStatusLineRecord.capture(
            Data(input.utf8),
            capturedAt: capturedAt
        )
        let encoded = try record.encoded()
        let persisted = String(decoding: encoded, as: UTF8.self)

        XCTAssertEqual(record.capturedAt, capturedAt)
        XCTAssertEqual(record.fiveHour?.usedPercentage, 11)
        XCTAssertEqual(record.sevenDay?.usedPercentage, 18)
        XCTAssertEqual(record.sevenDaySonnet?.usedPercentage, 7)
        XCTAssertNil(record.sevenDayOpus)
        XCTAssertFalse(persisted.contains("session_id"))
        XCTAssertFalse(persisted.contains("transcript"))
        XCTAssertFalse(persisted.contains("token"))
        XCTAssertFalse(persisted.contains("secret"))
    }

    func testClaudeStatusLineCacheMapsLiveFiveHourWindow() throws {
        let input = #"{"rate_limits":{"five_hour":{"used_percentage":11,"resets_at":1800016200.25},"seven_day":{"used_percentage":18,"resets_at":1800259200}}}"#
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let record = try ClaudeStatusLineRecord.capture(
            Data(input.utf8),
            capturedAt: capturedAt
        )
        let cache = SafeClaudeStatusLineCache(data: { try record.encoded() })

        let reading = try cache.read(now: capturedAt.addingTimeInterval(30))

        XCTAssertEqual(reading.capturedAt, capturedAt)
        XCTAssertEqual(reading.windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(reading.windows.map(\.usedFraction), [0.11, 0.18])
        XCTAssertEqual(reading.windows[0].resetsAt,
                       Date(timeIntervalSince1970: 1_800_016_200.25))
    }

    func testClaudeStatusLineCacheRejectsExpiredSessionWindow() throws {
        let input = #"{"rate_limits":{"five_hour":{"used_percentage":11,"resets_at":1800000060}}}"#
        let record = try ClaudeStatusLineRecord.capture(
            Data(input.utf8),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let cache = SafeClaudeStatusLineCache(data: { try record.encoded() })

        XCTAssertThrowsError(
            try cache.read(now: Date(timeIntervalSince1970: 1_800_000_061))
        )
        XCTAssertThrowsError(
            try ClaudeStatusLineRecord.capture(
                Data(input.utf8),
                capturedAt: Date(timeIntervalSince1970: 1_800_000_061)
            )
        )
    }

    func testClaudeProviderPrefersAValidCLIReading() async throws {
        let profile = ClaudeProfile.default(
            home: URL(fileURLWithPath: "/tmp/codenotch-safe-claude-profile")
        )
        let cli = ClaudeUsageCLI(binary: URL(fileURLWithPath: "/fake/claude")) { _ in
            "Current session: 34% used"
        }
        let cache = SafeClaudeUsageCache(data: {
            Data(#"{"cachedUsageUtilization":{"fetchedAtMs":1800000000000,"utilization":{"five_hour":{"utilization":91}}}}"#.utf8)
        })
        let provider = ClaudeCLIOnlyProvider(profile: profile, cli: cli, cache: cache)

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.id, "claude")
        XCTAssertEqual(snapshot.windows.map(\.id), ["session"])
        XCTAssertEqual(snapshot.windows.first?.usedFraction, 0.34)
        XCTAssertEqual(snapshot.headlineID, "session")
        XCTAssertEqual(snapshot.status, .ok)
    }

    func testClaudeProviderPrefersFreshStatusLineReadingOverCLI() async throws {
        let profile = ClaudeProfile.default(
            home: URL(fileURLWithPath: "/tmp/codenotch-safe-claude-status-line")
        )
        let capturedAt = Date()
        let input = #"{"rate_limits":{"five_hour":{"used_percentage":11,"resets_at":4102444800},"seven_day":{"used_percentage":18,"resets_at":4102444800}}}"#
        let record = try ClaudeStatusLineRecord.capture(
            Data(input.utf8),
            capturedAt: capturedAt
        )
        let statusLineCache = SafeClaudeStatusLineCache(data: { try record.encoded() })
        let cli = ClaudeUsageCLI(binary: URL(fileURLWithPath: "/fake/claude")) { _ in
            "Current session: 34% used"
        }
        let vendorCache = SafeClaudeUsageCache(data: {
            Data(#"{"cachedUsageUtilization":{"fetchedAtMs":1800000000000,"utilization":{"five_hour":{"utilization":91}}}}"#.utf8)
        })
        let provider = ClaudeCLIOnlyProvider(
            profile: profile,
            cli: cli,
            statusLineCache: statusLineCache,
            cache: vendorCache
        )

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.windows.map(\.usedFraction), [0.11, 0.18])
        XCTAssertEqual(snapshot.status, .ok)
    }

    func testClaudeProviderFallsBackToDatedLocalCache() async throws {
        let profile = ClaudeProfile.default(
            home: URL(fileURLWithPath: "/tmp/codenotch-safe-claude-cache")
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let cli = ClaudeUsageCLI(binary: URL(fileURLWithPath: "/fake/claude")) { _ in
            "print mode returned session cost instead of usage limits"
        }
        let cache = SafeClaudeUsageCache(data: {
            Data(#"{"cachedUsageUtilization":{"fetchedAtMs":1800000000000,"utilization":{"five_hour":{"utilization":43},"seven_day":{"utilization":16}}}}"#.utf8)
        })
        let provider = ClaudeCLIOnlyProvider(profile: profile, cli: cli, cache: cache)

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.windows.map(\.usedFraction), [0.43, 0.16])
        XCTAssertEqual(snapshot.status, .stale(since: fetchedAt))
        XCTAssertEqual(snapshot.headlineID, "session")
    }

    func testClaudeProviderRequiresAuthWhenCLIAndCacheAreUnavailable() async {
        let provider = ClaudeCLIOnlyProvider(
            profile: .default(home: URL(fileURLWithPath: "/tmp/codenotch-no-claude")),
            cli: nil,
            cache: nil
        )

        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("missing Claude CLI and cache must require authentication in Claude Code")
        } catch UsageProviderError.needsAuth {
            // Expected: the safe provider has no credential or network fallback.
        } catch {
            XCTFail("expected needsAuth, got \(error)")
        }
    }

    func testCursorEndpointIsExactAndHasOnlyRequiredHeaders() throws {
        let request = try CursorEndpoint.makeRequest(cookie: "account::token")

        XCTAssertEqual(request.url?.absoluteString, "https://cursor.com/api/usage-summary")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"),
                       "WorkosCursorSessionToken=account::token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(Set(request.allHTTPHeaderFields?.keys.map { $0 } ?? []),
                       ["Cookie", "Accept"])
    }

    func testCursorEndpointRejectsEveryOriginOrPathChange() {
        let altered = [
            "http://cursor.com/api/usage-summary",
            "https://evil.example/api/usage-summary",
            "https://cursor.com:444/api/usage-summary",
            "https://cursor.com/api/usage-summary/extra",
            "https://cursor.com/api/usage-summary?redirect=https://evil.example",
        ]

        for value in altered {
            XCTAssertThrowsError(
                try CursorEndpoint.makeRequest(
                    cookie: "account::token",
                    target: XCTUnwrap(URL(string: value))
                ),
                value
            )
        }
    }

    func testCursorCredentialLoaderReadsTheEditorDatabaseWithoutMutation() throws {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("codenotch-cursor-\(UUID().uuidString).vscdb")
        defer { try? FileManager.default.removeItem(at: store) }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);",
                                   nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,
            "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'fake-token');",
            nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,
            "INSERT INTO ItemTable VALUES ('cursorAuth/stripeMembershipAuthId', 'fake-account');",
            nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let before = try Data(contentsOf: store)
        let credentials = try CursorEditorCredentials.load(from: store)
        let after = try Data(contentsOf: store)

        XCTAssertEqual(credentials.accountID, "fake-account")
        XCTAssertEqual(credentials.accessToken, "fake-token")
        XCTAssertEqual(credentials.cookieValue, "fake-account::fake-token")
        XCTAssertEqual(after, before, "the credential database was modified")
    }

    func testCursorCredentialLoaderHasNoFallbackWhenEditorValuesAreMissing() throws {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("codenotch-cursor-empty-\(UUID().uuidString).vscdb")
        defer { try? FileManager.default.removeItem(at: store) }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);",
                                   nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        XCTAssertThrowsError(try CursorEditorCredentials.load(from: store)) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }

    func testCursorSessionKeepsNothingPersistent() {
        let configuration = CursorEndpoint.makeConfiguration()

        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testCursorRedirectDelegateRejectsEveryRedirect() throws {
        let delegate = RedirectRejectingSessionDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = try XCTUnwrap(URL(string: "https://cursor.com/api/usage-summary"))
        let redirected = try XCTUnwrap(URL(string: "https://cursor.com/another-path"))
        let task = session.dataTask(with: original)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: original,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirected.absoluteString]
        ))
        var result: URLRequest? = URLRequest(url: redirected)

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirected)
        ) { result = $0 }

        XCTAssertNil(result)
        task.cancel()
    }
}

/// A mutable counter shared with a `@Sendable` closure. Capturing a plain
/// `var` in such a closure mutates it from the wrong isolation domain —
/// Swift 6 mode turns that into an error. A class instance fixes it.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func bump() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}

@MainActor
private final class ActivityMonitorSpy: AgentActivityMonitor {
    private let subject = CurrentValueSubject<[AgentSession], Never>([])
    var sessions: [AgentSession] { subject.value }
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> {
        subject.eraseToAnyPublisher()
    }
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func send(_ sessions: [AgentSession]) { subject.send(sessions) }
}

@MainActor
final class ProviderActivityControllerTests: XCTestCase {
    func testDisconnectedMonitorDoesNotStartAndReconnectIsIdempotent() {
        let cursor = ActivityMonitorSpy()
        let controller = ProviderActivityController(
            monitors: ["cursor": cursor],
            disconnected: ["cursor"],
            onSessions: { _, _ in }
        )

        XCTAssertEqual(cursor.startCount, 0)
        controller.apply(disconnected: [])
        controller.apply(disconnected: [])
        XCTAssertEqual(cursor.startCount, 1)
    }

    func testDisconnectStopsMonitorAndClearsItsSessions() {
        let cursor = ActivityMonitorSpy()
        var deliveries: [(String, [AgentSession])] = []
        let controller = ProviderActivityController(
            monitors: ["cursor": cursor],
            disconnected: [],
            onSessions: { deliveries.append(($0, $1)) }
        )

        controller.apply(disconnected: ["cursor"])

        XCTAssertEqual(cursor.stopCount, 1)
        XCTAssertEqual(deliveries.last?.0, "cursor")
        XCTAssertTrue(deliveries.last?.1.isEmpty == true)
    }
}

final class AboutMetadataTests: XCTestCase {
    func testCreditsAndLinksIdentifyUpstreamAndSafeFork() {
        XCTAssertEqual(AboutMetadata.originalAuthor, "Vinz")
        XCTAssertEqual(AboutMetadata.copyright, "Copyright (c) 2026 Vinz")
        XCTAssertEqual(AboutMetadata.originalSourceURL.absoluteString,
                       "https://github.com/vinzdg/codenotch")
        XCTAssertEqual(AboutMetadata.safeSourceURL.absoluteString,
                       "https://github.com/x950827/codenotch-safe")
        XCTAssertEqual(AboutMetadata.auditURL.absoluteString,
                       "https://github.com/x950827/codenotch-safe/blob/main/SECURITY-AUDIT.md")
        XCTAssertEqual(AboutMetadata.licenseURL.absoluteString,
                       "https://github.com/vinzdg/codenotch/blob/main/LICENSE")
    }

    func testSafeChangesNameEveryAuditedBoundary() {
        let text = AboutMetadata.safeChanges.joined(separator: " ")
        for required in ["Claude", "Cursor", "Codex", "Keychain",
                         "bearer", "web view", "updater", "CI"] {
            XCTAssertTrue(text.localizedCaseInsensitiveContains(required), required)
        }
    }
}

@MainActor
final class AppMenuActionsTests: XCTestCase {
    func testCommandsRouteToTheirOwnWindows() {
        var opened: [String] = []
        let actions = AppMenuActions(
            showAbout: { opened.append("about") },
            showSettings: { opened.append("settings") }
        )

        actions.openAbout()
        actions.openSettings()

        XCTAssertEqual(opened, ["about", "settings"])
    }
}

final class SafeDisclosureTests: XCTestCase {
    func testAccountCopyMatchesSafeCredentialBoundary() {
        let text = AboutMetadata.accountAccessExplanation
        XCTAssertTrue(text.contains("disabled provider is not queried"))
        XCTAssertTrue(text.contains("Cursor"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("Always Allow"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("Keychain password"))
    }

    func testBundledLicenseMatchesRepositoryLicense() throws {
        let bundled = try XCTUnwrap(Bundle(for: Self.self)
            .url(forResource: "LICENSE", withExtension: "txt"))
        let text = try String(contentsOf: bundled, encoding: .utf8)
        XCTAssertTrue(text.contains("MIT License"))
        XCTAssertTrue(text.contains("Copyright (c) 2026 Vinz"))
        XCTAssertTrue(text.contains("copies or substantial portions"))
    }

    // MARK: - OpenCode Go boundary

    /// The recorded response shape — pinned here so a change in OpenCode's
    /// endpoint either gets re-pinned deliberately or fails the boundary test.
    private static let openCodeRecordedJSON = """
    {"usage":{
      "rolling":{"status":"ok","percent":13,"resetsAt":"2030-01-15T12:30:00.250Z"},
      "weekly": {"status":"ok","percent":42,"resetsAt":"2030-01-18T00:00:00Z"},
      "monthly":{"status":"ok","percent":7, "resetsAt":"2030-02-03T13:09:45Z"}}}
    """

    func testOpenCodeUsageParserPinsTheRecordedShape() throws {
        let now = Date(timeIntervalSince1970: 1_893_456_000)
        let windows = try OpenCodeUsage.windows(
            fromJSON: Self.openCodeRecordedJSON,
            now: now
        )

        XCTAssertEqual(windows.map(\.id), ["rolling", "weekly", "monthly"])
        XCTAssertEqual(windows.map(\.label), ["5h limit", "Weekly limit", "Monthly limit"])
        XCTAssertEqual(windows.map(\.usedFraction), [0.13, 0.42, 0.07])
        XCTAssertEqual(windows[0].resetsAt,
                       Date(timeIntervalSince1970: 1_894_566_600.250))
        XCTAssertEqual(windows[1].resetsAt,
                       Date(timeIntervalSince1970: 1_898_937_600))
        XCTAssertEqual(windows[2].resetsAt,
                       Date(timeIntervalSince1970: 1_924_165_785))
    }

    func testOpenCodeUsageParserRejectsShapeChanges() {
        XCTAssertThrowsError(try OpenCodeUsage.windows(
            fromJSON: #"{"usage":{"rolling":{"status":"ok","percent":"13"}}}"#
        ))
        XCTAssertThrowsError(try OpenCodeUsage.windows(
            fromJSON: #"{"usage":{"rolling":{"status":"ok","resetsAt":"2030-01-15T12:30:00Z"}}}"#
        ))
        XCTAssertThrowsError(try OpenCodeUsage.windows(
            fromJSON: #"{"usage":{}}"#
        ))
    }

    func testOpenCodeUsageHeadlineIsTheRollingWindow() throws {
        let windows = try OpenCodeUsage.windows(fromJSON: Self.openCodeRecordedJSON)
        XCTAssertEqual(windows.map(\.id).first, "rolling")
    }

    func testOpenCodeCredentialsReadOnlyOpenCodeGoEntryObjectShape() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"opencode-go":{"type":"api","key":"sk-go-live"}}"#.utf8).write(to: url)

        let credential = try XCTUnwrap(OpenCodeCredentials.load(from: url))

        XCTAssertEqual(credential.token, "sk-go-live")
    }

    func testOpenCodeCredentialsAcceptTheBareStringShape() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"opencode-go":"sk-go-live"}"#.utf8).write(to: url)

        XCTAssertEqual(try XCTUnwrap(OpenCodeCredentials.load(from: url)).token,
                       "sk-go-live")
    }

    func testOpenCodeCredentialsRejectEmptyKeyAndIgnoreOtherEntries() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        // Empty `opencode-go` and live `openai`/`deepseek` entries — only the
        // opencode-go slot decides what the provider reads.
        try Data(
            #"{"opencode-go":{"type":"api","key":""},"openai":{"type":"oauth","access":"oa"},"deepseek":{"type":"api","key":"sk-deepseek"}}"#
                .utf8
        ).write(to: url)

        XCTAssertNil(OpenCodeCredentials.load(from: url))
    }

    func testOpenCodeCredentialsReturnNilWhenFileMissingOrUnreadable() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-missing-\(UUID().uuidString).json")

        XCTAssertNil(OpenCodeCredentials.load(from: missing))
    }

    func testOpenCodeEndpointIsExactAndHasOnlyRequiredHeaders() throws {
        let request = try OpenCodeEndpoint.makeRequest(token: "sk-go-live")

        XCTAssertEqual(request.url?.absoluteString, "https://opencode.ai/zen/go/v1/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Bearer sk-go-live")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(Set(request.allHTTPHeaderFields?.keys.map { $0 } ?? []),
                       ["Authorization", "Accept"])
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testOpenCodeEndpointRejectsEveryOriginOrPathChange() {
        let altered = [
            "http://opencode.ai/zen/go/v1/usage",
            "https://evil.example/zen/go/v1/usage",
            "https://opencode.ai:444/zen/go/v1/usage",
            "https://opencode.ai/zen/go/v1/usage/extra",
            "https://opencode.ai/zen/go/v1/usage?redirect=https://evil.example",
            "https://opencode.ai/zen/go/v1/usage#fragment",
            "https://user:pass@opencode.ai/zen/go/v1/usage",
        ]

        for value in altered {
            XCTAssertThrowsError(
                try OpenCodeEndpoint.makeRequest(
                    token: "sk-go-live",
                    target: XCTUnwrap(URL(string: value))
                ),
                value
            )
        }
    }

    func testOpenCodeEndpointRejectsMalformedTokens() {
        XCTAssertThrowsError(try OpenCodeEndpoint.makeRequest(token: ""))
        XCTAssertThrowsError(try OpenCodeEndpoint.makeRequest(token: "line1\rline2"))
        XCTAssertThrowsError(try OpenCodeEndpoint.makeRequest(token: "line1\nline2"))
    }

    func testOpenCodeSessionKeepsNothingPersistent() {
        let configuration = OpenCodeEndpoint.makeConfiguration()

        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
    }

    func testOpenCodeBackoffKeepsASixtySecondFloor() {
        XCTAssertEqual(OpenCodeEndpoint.backoff(forAttempt: 0, retryAfter: nil), 60,
                       accuracy: 0.0001)
        XCTAssertEqual(OpenCodeEndpoint.backoff(forAttempt: 1, retryAfter: nil), 120,
                       accuracy: 0.0001)
        XCTAssertEqual(OpenCodeEndpoint.backoff(forAttempt: 2, retryAfter: nil), 240,
                       accuracy: 0.0001)
        XCTAssertEqual(OpenCodeEndpoint.backoff(forAttempt: 3, retryAfter: nil), 480,
                       accuracy: 0.0001)
        XCTAssertEqual(OpenCodeEndpoint.backoff(forAttempt: 4, retryAfter: nil), 900,
                       accuracy: 0.0001)
        XCTAssertEqual(OpenCodeEndpoint.backoff(forAttempt: 99, retryAfter: nil), 900,
                       accuracy: 0.0001)
    }

    func testOpenCodeBackoffHonoursRetryAfterOnlyAsAFloorRaiser() {
        // A short hint is ignored — the 60s floor prevents walking straight
        // back into the limit it was just told to back off from.
        XCTAssertEqual(OpenCodeEndpoint.backoff(forAttempt: 0, retryAfter: 5), 60,
                       accuracy: 0.0001)
        // A long hint is honoured.
        XCTAssertEqual(OpenCodeEndpoint.backoff(forAttempt: 0, retryAfter: 180), 180,
                       accuracy: 0.0001)
    }

    func testOpenCodeRetryAfterParsesSecondsAndHTTPDate() throws {
        let secondsHeader = HTTPURLResponse(
            url: OpenCodeEndpoint.url,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": "42"]
        )
        let seconds = try XCTUnwrap(OpenCodeEndpoint.retryAfter(from: secondsHeader))
        XCTAssertEqual(seconds, 42, accuracy: 0.0001)

        let future = Date().addingTimeInterval(300)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let dateHeader = HTTPURLResponse(
            url: OpenCodeEndpoint.url,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": formatter.string(from: future)]
        )
        let parsed = try? XCTUnwrap(OpenCodeEndpoint.retryAfter(from: dateHeader))
        XCTAssertEqual(parsed ?? 0, future.timeIntervalSinceNow, accuracy: 1.0)

        XCTAssertNil(OpenCodeEndpoint.retryAfter(from: nil))
        let malformed = HTTPURLResponse(
            url: OpenCodeEndpoint.url,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": "not-a-number"]
        )
        XCTAssertNil(OpenCodeEndpoint.retryAfter(from: malformed))
    }

    @MainActor
    func testOpenCodeSafeProviderUsesOnlyTheAuditedEndpoint() async throws {
        // 200 on the exact endpoint.
        let success = OpenCodeSafeProvider(
            session: OpenCodeEndpoint.makeStubbedSession { request in
                XCTAssertEqual(request.url?.absoluteString,
                               "https://opencode.ai/zen/go/v1/usage")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                               "Bearer sk-go-live")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"),
                               "application/json")
                return .success(body: Self.openCodeRecordedJSON)
            },
            loadCredentials: { OpenCodeCredentials.Credential(token: "sk-go-live") }
        )

        let snapshot = try await success.fetchSnapshot()
        XCTAssertEqual(snapshot.id, "opencode")
        XCTAssertEqual(snapshot.windows.map(\.id), ["rolling", "weekly", "monthly"])
        XCTAssertEqual(snapshot.windows.first?.usedFraction, 0.13)
        XCTAssertEqual(snapshot.headlineID, "rolling")
        XCTAssertEqual(snapshot.fidelity, .official)
    }

    func testOpenCodeSafeProviderMapsMissingKeyToNeedsAuth() async {
        let provider = OpenCodeSafeProvider(
            session: OpenCodeEndpoint.makeStubbedSession { _ in
                .success(body: Self.openCodeRecordedJSON)
            },
            loadCredentials: { throw UsageProviderError.needsAuth }
        )

        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("missing credential must surface as needsAuth")
        } catch UsageProviderError.needsAuth {
            // Expected: the loader throws needsAuth before the network
            // is touched, so the stubbed session is never asked.
        } catch {
            XCTFail("expected needsAuth, got \(error)")
        }
    }

    func testOpenCodeSafeProviderMaps401ToNeedsAuth() async {
        let provider = OpenCodeSafeProvider(
            session: OpenCodeEndpoint.makeStubbedSession { _ in
                .status(401, headers: [:], body: "")
            },
            loadCredentials: { OpenCodeCredentials.Credential(token: "sk-go-live") }
        )

        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("401 must surface as needsAuth")
        } catch UsageProviderError.needsAuth {
            // Expected: a key without a Go plan answers 401, the same as a
            // bad key. Both read as "nothing readable here".
        } catch {
            XCTFail("expected needsAuth, got \(error)")
        }
    }

    func testOpenCodeSafeProviderMaps403ToNothingMetered() async {
        let provider = OpenCodeSafeProvider(
            session: OpenCodeEndpoint.makeStubbedSession { _ in
                .status(403, headers: [:], body: "")
            },
            loadCredentials: { OpenCodeCredentials.Credential(token: "sk-go-live") }
        )

        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("403 must surface as nothingMetered")
        } catch UsageProviderError.nothingMetered {
            // Expected: the key is valid, the plan is not Go — that is
            // metering nothing, not an error.
        } catch {
            XCTFail("expected nothingMetered, got \(error)")
        }
    }

    func testOpenCodeSafeProviderRecordsPersistentBackoffOn429() async throws {
        let defaults = UserDefaults(suiteName: "OpenCodeSafeProviderTests.\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: "OpenCodeSafeProviderTests") }
        let archive = UsageArchive(defaults: defaults)

        let provider = OpenCodeSafeProvider(
            session: OpenCodeEndpoint.makeStubbedSession { _ in
                .status(429, headers: ["Retry-After": "0"], body: "")
            },
            loadCredentials: { OpenCodeCredentials.Credential(token: "sk-go-live") },
            archive: archive
        )

        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("429 must surface as rateLimited")
        } catch UsageProviderError.rateLimited(let retryAfter) {
            // The server's hint is honoured only as a floor-raiser — the
            // returned wait is at least the 60-second floor.
            XCTAssertGreaterThanOrEqual(retryAfter, 60)
        }

        let nextAttempt = archive.loadBackoffUntil(providerID: "opencode")
        XCTAssertNotNil(nextAttempt, "backoff deadline must survive the request")
        XCTAssertGreaterThan(nextAttempt ?? .distantPast, Date().addingTimeInterval(30))

        // A follow-up fetch during the penalty must not touch the network —
        // the next attempt deadline is still in the future.
        let secondCallCount = CallCounter()
        let secondSession = OpenCodeEndpoint.makeStubbedSession { _ in
            secondCallCount.bump()
            return .status(500, headers: [:], body: "")
        }
        let secondProvider = OpenCodeSafeProvider(
            session: secondSession,
            loadCredentials: { OpenCodeCredentials.Credential(token: "sk-go-live") },
            archive: archive
        )
        do {
            _ = try await secondProvider.fetchSnapshot()
            XCTFail("backoff in progress must not issue a request")
        } catch UsageProviderError.rateLimited {
            // Expected: the deadline from the first 429 is still ahead, so
            // the second fetch is skipped without a request.
        }
        XCTAssertEqual(secondCallCount.value, 0)
    }

    func testOpenCodeSafeProviderRejectsARedirectedResponse() async {
        let provider = OpenCodeSafeProvider(
            session: OpenCodeEndpoint.makeStubbedSession { _ in
                .redirected(to: "https://evil.example/api/usage")
            },
            loadCredentials: { OpenCodeCredentials.Credential(token: "sk-go-live") }
        )

        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("a redirect to a different host must not be accepted")
        } catch OpenCodeBoundaryError.invalidEndpoint {
            // Expected: the response URL is checked against the allowlist
            // even when the status code would otherwise look healthy.
        } catch {
            XCTFail("expected invalidEndpoint, got \(error)")
        }
    }

    func testOpenCodeSafeProviderDoesNotMutateTheCredentialsFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data(#"{"opencode-go":{"type":"api","key":"sk-go-live"}}"#.utf8)
        try original.write(to: url)

        let provider = OpenCodeSafeProvider(
            session: OpenCodeEndpoint.makeStubbedSession { _ in
                .status(500, headers: [:], body: "")
            },
            loadCredentials: {
                // The test wrote `original` just above, so the key is
                // present; force-unwrap is honest here.
                try XCTUnwrap(OpenCodeCredentials.load(from: url))
            }
        )

        _ = try? await provider.fetchSnapshot()

        XCTAssertEqual(try Data(contentsOf: url), original,
                       "the credential file was modified")
    }

    @MainActor
    func testSafe12PreferenceKeysRemainReadable() {
        let suite = "Safe12Preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["cursor"], forKey: "hiddenProviders")
        defaults.set(NotchScreenScope.allDisplays.rawValue, forKey: "notchScope")
        defaults.set(AppPresence.menuBar.rawValue, forKey: "appPresence")

        let preferences = Preferences(defaults: defaults)

        XCTAssertEqual(preferences.disconnectedProviders, Set(["cursor"]))
        XCTAssertEqual(preferences.notchScope, .allDisplays)
        XCTAssertEqual(preferences.appPresence, .menuBar)
    }
}
