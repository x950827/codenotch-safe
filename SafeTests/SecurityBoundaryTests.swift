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
            ]
        )

        XCTAssertEqual(environment["HOME"], "/tmp/home")
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/tmp/.claude-work")
        XCTAssertEqual(environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"], "1")
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
            // Expected: there is deliberately no token or keychain fallback.
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
