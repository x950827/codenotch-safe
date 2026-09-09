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

    func testClaudeProviderUsesOnlyTheInjectedCLI() async throws {
        let profile = ClaudeProfile.default(
            home: URL(fileURLWithPath: "/tmp/codenotch-safe-claude-profile")
        )
        let cli = ClaudeUsageCLI(binary: URL(fileURLWithPath: "/fake/claude")) { _ in
            "Current session: 34% used"
        }
        let provider = ClaudeCLIOnlyProvider(profile: profile, cli: cli)

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.id, "claude")
        XCTAssertEqual(snapshot.windows.map(\.id), ["session"])
        XCTAssertEqual(snapshot.windows.first?.usedFraction, 0.34)
        XCTAssertEqual(snapshot.headlineID, "session")
    }

    func testClaudeProviderNeverFallsBackWhenCLIIsUnavailable() async {
        let provider = ClaudeCLIOnlyProvider(
            profile: .default(home: URL(fileURLWithPath: "/tmp/codenotch-no-claude")),
            cli: nil
        )

        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("a missing Claude CLI must require authentication in Claude Code")
        } catch UsageProviderError.needsAuth {
            // Expected: there is deliberately no token fallback.
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
