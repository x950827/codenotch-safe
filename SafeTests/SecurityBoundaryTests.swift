import Foundation
import XCTest
@testable import Codenotch

final class SecurityBoundaryTests: XCTestCase {
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
        XCTAssertTrue((messages[2]["params"] as? [String: Any])?.isEmpty == true)
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
        XCTAssertThrowsError(CodexAppServerProtocol.parse(
            #"{"id":0,"result":{}}"#
        ))
        XCTAssertThrowsError(CodexAppServerProtocol.parse(
            #"{"id":1,"error":{"code":-32001,"message":"authentication required"}}"#
        ))
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
}
