# Codenotch Safe Fork Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce and install an audited local Codenotch build whose only providers are Claude Code, Codex, and Cursor, and whose process never reads Claude or Codex bearer tokens.

**Architecture:** Claude and Codex usage is requested through their installed CLIs with fixed commands and bounded subprocess lifetimes. Cursor remains the single direct credential path: a read-only editor database supplies an in-memory cookie to an ephemeral, redirect-rejecting client fixed to one Cursor endpoint. XcodeGen compiles an explicit source allowlist, while a local `swiftc` script produces the same ad-hoc signed app without requiring full Xcode.

**Tech Stack:** Swift 6.3, AppKit, SwiftUI, Combine, Foundation, SQLite3, ServiceManagement, XCTest, XcodeGen, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-08-codenotch-safe-fork-design.md`

## Global Constraints

- The runtime provider set is exactly Claude Code, Codex, and Cursor.
- Codenotch must not read Claude or Codex bearer tokens.
- The only Codenotch-owned external URL is `https://cursor.com/api/usage-summary`.
- Cursor transport rejects redirects and uses no persistent URL cache, cookie store, or credential store.
- No raw provider response, credential, local path, or session title is logged.
- Usage refresh is fixed at five minutes; activity probes are fixed at five seconds.
- The build has no Sparkle dependency, update feed, analytics SDK, App Sandbox entitlement, or other entitlement.
- Idle CPU must average below 1% over five minutes and resident memory must remain below 100 MB after startup.

---

### Task 1: Safe Provider Contract Tests

**Files:**
- Create: `SafeTests/SecurityBoundaryTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: `UsageProvider`, `LimitWindow`, `ProviderSnapshot`, and existing usage parsers.
- Produces: executable expectations for `CodexAppServerProtocol`, `CursorEndpoint`, and provider source selection.

- [ ] **Step 1: Add failing protocol and endpoint tests**

Create XCTest cases asserting that `CodexAppServerProtocol.input` contains exactly an `initialize` request, `initialized` notification, and `account/rateLimits/read`; that a fixture response produces primary and secondary windows; that `CursorEndpoint.makeRequest(cookie:)` rejects altered scheme/host/path values; and that its production request has only the `Cookie` and `Accept` headers.

```swift
func testCodexHandshakeRequestsOnlyRateLimits() throws {
    let lines = CodexAppServerProtocol.input.split(separator: "\n")
    XCTAssertEqual(lines.count, 3)
    XCTAssertTrue(lines[2].contains("account/rateLimits/read"))
}

func testCursorEndpointIsExact() throws {
    let request = try CursorEndpoint.makeRequest(cookie: "account::token")
    XCTAssertEqual(request.url?.absoluteString, "https://cursor.com/api/usage-summary")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"),
                   "WorkosCursorSessionToken=account::token")
}
```

- [ ] **Step 2: Run the new target and confirm symbol failures**

Run: `make test-ci`

Expected on a full Xcode runner: compilation fails because `CodexAppServerProtocol` and `CursorEndpoint` do not exist. On this Mac, record that `xcodebuild` is unavailable and use the manual type-check in Task 5 after implementation.

- [ ] **Step 3: Restrict the test target to `SafeTests`**

Change `CodenotchTests.sources` to `SafeTests`, leaving the upstream tests in the repository as historical reference rather than compiling credential-provider tests into the hardened target.

- [ ] **Step 4: Commit the failing contract**

Run:

```bash
git add SafeTests project.yml
git commit -m "test: define safe provider boundaries"
```

### Task 2: CLI-Only Claude and Codex Providers

**Files:**
- Create: `Sources/Safe/ClaudeCLIOnlyProvider.swift`
- Create: `Sources/Safe/CodexAppServerProvider.swift`
- Create: `Sources/Safe/ClaudeUsageLabels.swift`
- Modify: `Sources/Providers/ClaudeUsageCLI.swift`
- Extend: `SafeTests/SecurityBoundaryTests.swift`

**Interfaces:**
- Consumes: `ClaudeUsageCLI.read(profile:now:)`, `ClaudeProfile`, `UsageProvider`, and `CodexUsage.label(windowSeconds:fallback:)`.
- Produces: `ClaudeCLIOnlyProvider`, `CodexAppServerProvider`, `CodexAppServerProtocol.parse(_:)`, and `CodexAppServerExecutable.locate()`.

- [ ] **Step 1: Add failing parse and failure-path tests**

Use a newline-delimited fixture with unrelated notifications around response id `1`; assert the `codex` bucket is preferred from `rateLimitsByLimitId`, percentages are converted from 0–100 to 0–1, and missing/auth-error responses throw without reading `CodexCredentials`.

- [ ] **Step 2: Move Claude label ordering behind a token-free helper**

Define `ClaudeUsageLabels.label(forKind:)` and `ClaudeUsageLabels.displayOrder(_:_:)`; update `ClaudeUsageCLI` to use those methods so the safe target does not need `ClaudeOAuthProvider.swift` or `ClaudeCredentials.swift`.

- [ ] **Step 3: Implement the CLI-only Claude provider**

The provider resolves only documented Claude install locations, invokes only `claude /usage`, returns `.needsAuth` when the binary or parse is unavailable, and implements `forgetCachedCredential()` and `presentSignIn()` as no-ops.

- [ ] **Step 4: Implement the Codex app-server protocol**

`CodexAppServerExecutable` runs the first executable found in `.local/bin/codex`, `opt/homebrew/bin/codex`, `usr/local/bin/codex`, or the ChatGPT app bundle. It sends this JSONL and closes stdin:

```json
{"method":"initialize","id":0,"params":{"clientInfo":{"name":"codenotch_safe_local","title":"Codenotch Safe Local","version":"1.0.0"}}}
{"method":"initialized","params":{}}
{"method":"account/rateLimits/read","id":1}
```

It reads stdout to EOF, enforces a 20-second watchdog, ignores notifications, and parses only response id `1`. The provider exposes no account token or token-derived identity.

- [ ] **Step 5: Type-check the provider layer**

Run the local `swiftc -typecheck` command introduced in Task 5. Expected: no diagnostics.

- [ ] **Step 6: Commit CLI-only providers**

Run:

```bash
git add Sources/Safe Sources/Providers/ClaudeUsageCLI.swift SafeTests
git commit -m "feat: read Claude and Codex limits through their CLIs"
```

### Task 3: Strict Cursor Boundary

**Files:**
- Create: `Sources/Safe/CursorEditorCredentials.swift`
- Create: `Sources/Safe/CursorEndpoint.swift`
- Create: `Sources/Safe/CursorSafeProvider.swift`
- Extend: `SafeTests/SecurityBoundaryTests.swift`

**Interfaces:**
- Consumes: `SQLiteStore.open(_:)`, `CursorUsage.windows(fromJSON:)`, and `UsageProvider`.
- Produces: `CursorEditorCredentials.load(from:)`, `CursorEndpoint.makeRequest(cookie:)`, `RedirectRejectingSessionDelegate`, and `CursorSafeProvider`.

- [ ] **Step 1: Add failing read-only and redirect tests**

Create a temporary SQLite `ItemTable` containing a fake token and account id; assert the loader returns them without mutating the database. Invoke the redirect delegate with a synthetic response/request and assert its completion receives `nil`.

- [ ] **Step 2: Implement editor-only credential loading**

Read `cursorAuth/accessToken` and `cursorAuth/stripeMembershipAuthId` from Cursor's editor database using `SQLiteStore`. Do not import Security and do not fall back to cursor-agent Keychain.

- [ ] **Step 3: Implement the exact endpoint client**

Construct a fresh request only after validating scheme `https`, host `cursor.com`, nil/default port, and path `/api/usage-summary`. Configure `URLSessionConfiguration.ephemeral` with nil cookie/credential storage, nil URL cache, `reloadIgnoringLocalCacheData`, and a redirect delegate that always returns `nil`.

- [ ] **Step 4: Implement the provider without body logging**

Send the in-memory session cookie, decode the body directly with `CursorUsage`, and log only provider id, status code, and normalized window count through existing `UsageStore` messages.

- [ ] **Step 5: Run type-check and commit**

Run the Task 5 type-check, then:

```bash
git add Sources/Safe SafeTests
git commit -m "feat: confine Cursor usage to one endpoint"
```

### Task 4: Remove Updater and Unrelated Runtime Paths

**Files:**
- Modify: `Sources/App/AppDelegate.swift`
- Replace: `Sources/App/Updater.swift`
- Modify: `Sources/Settings/SettingsView.swift`
- Modify: `Sources/Model/UsageStore.swift`
- Modify: `project.yml`
- Modify: `Sources/Info.plist`

**Interfaces:**
- Consumes: the three safe providers from Tasks 2 and 3.
- Produces: a macOS target whose compiled source set has no unrelated network or credential adapter.

- [ ] **Step 1: Register only the safe providers**

Build `UsageStore` from `ClaudeCLIOnlyProvider` instances plus `CursorSafeProvider()` and `CodexAppServerProvider()`. Pass both refresh intervals as `300`. Register only Cursor, Codex, and Claude activity monitors, each with a five-second liveness interval.

- [ ] **Step 2: Remove discovery and sensitive log content**

Delete the WebView provider setup, `CODENOTCH_DISCOVER` hook, public profile-path log, extra monitor construction, author URL, and setup text naming removed providers. Keep logs to fixed messages and non-sensitive counts/status codes.

- [ ] **Step 3: Replace Sparkle updater with an offline status object**

Remove `import Sparkle`. Preserve the small `Updater` interface required by settings, but make `automatic` always false, `start()` a no-op, and `checkNow()` report that audited builds are updated only from reviewed source. Render this as static explanatory text rather than an enabled auto-update toggle.

- [ ] **Step 4: Restrict XcodeGen sources and dependencies**

Remove the Sparkle package and target dependency. Exclude every upstream provider except `ClaudeProfile.swift`, `ClaudeUsageCLI.swift`, `CodexUsage.swift`, `CursorUsage.swift`, `GlyphOutline.swift`, `ProviderAccount.swift`, `ProviderGlyph.swift`, `SQLiteStore.swift`, and `UsageProvider.swift`. Exclude the Antigravity, Gemini, and Grok activity monitor files. Include `Sources/Safe`.

- [ ] **Step 5: Remove update keys from the plist**

Delete `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`, and `SUScheduledCheckInterval` from generated settings and `Sources/Info.plist`.

- [ ] **Step 6: Run endpoint and dependency scans**

Run:

```bash
rg -n 'hivinz|sparkle|sentry|posthog|telemetry|analytics' Sources project.yml
rg -n 'https?://' Sources/Safe Sources/App Sources/Model
```

Expected: no update/analytics match; the only runtime network URL is Cursor's exact endpoint, while account-management links are clearly user-initiated UI destinations.

- [ ] **Step 7: Commit runtime reduction**

Run:

```bash
git add Sources project.yml SafeTests
git commit -m "feat: compile only the audited provider surface"
```

### Task 5: Reproducible Local Build and CI

**Files:**
- Create: `Scripts/safe-source-list.sh`
- Create: `Scripts/build-safe-local.sh`
- Modify: `.github/workflows/ci.yml`
- Modify: `Makefile`

**Interfaces:**
- Consumes: the XcodeGen source allowlist from Task 4.
- Produces: `build/safe/Codenotch.app`, a type-check command, an ad-hoc signature, and a CI artifact built from the same allowlist.

- [ ] **Step 1: Add a canonical source-list script**

Print NUL-delimited Swift paths for all non-provider/non-removed-session sources plus the explicitly allowed provider and safe files. Both local `swiftc` and security scans use this script.

- [ ] **Step 2: Add the local app-bundle builder**

Create `build/safe/Codenotch.app/Contents/{MacOS,Resources}`, compile the canonical sources with `xcrun swiftc -O -parse-as-library -target arm64-apple-macosx26.0 -lsqlite3`, write a minimal plist with bundle id `local.audited.codenotch`, copy the menu-bar SVG, and run `/usr/bin/codesign --force --deep --sign -`.

- [ ] **Step 3: Add Make targets**

Add `safe-typecheck`, `safe-build`, and `safe-verify`. Verification runs `codesign --verify --deep --strict`, dumps entitlements, hashes the executable, and rejects forbidden host strings.

- [ ] **Step 4: Update CI**

Generate the project, run the SafeTests target, run `safe-verify`, zip `Codenotch.app`, and upload it with `actions/upload-artifact@v4`. Pin every action by a full commit SHA before publishing the fork.

- [ ] **Step 5: Run local build and verification**

Run: `make safe-typecheck safe-build safe-verify`

Expected: exit 0; empty entitlement plist; no forbidden domains in executable; SHA-256 printed.

- [ ] **Step 6: Commit build chain**

Run:

```bash
git add Scripts Makefile .github/workflows/ci.yml
git commit -m "build: add reproducible audited app bundle"
```

### Task 6: Audit, Runtime Measurement, Fork, and Installation

**Files:**
- Create: `SECURITY-AUDIT.md`
- Create: `/Users/daniil.tagan/Documents/Codex/2026-09-08/new-chat/outputs/codenotch-security-audit.md` as the user-facing copy.

**Interfaces:**
- Consumes: verified app and git history from Tasks 1–5.
- Produces: audit evidence, remote GitHub fork, and an installed `/Applications/Codenotch Safe.app` only if every mandatory check passes.

- [ ] **Step 1: Inventory compiled imports, strings, entitlements, and signature**

Record source commit, fork commit, executable SHA-256, `otool -L`, `codesign -d --entitlements :-`, `codesign --verify`, and forbidden-domain scan output.

- [ ] **Step 2: Launch the built app and measure five minutes**

Sample PID RSS and CPU every five seconds for 300 seconds. Record maximum/median RSS and average CPU. Use `lsof -nP -iTCP` during initial and scheduled refreshes to attribute sockets by owning PID; distinguish Codenotch from its child Claude/Codex processes.

- [ ] **Step 3: Write the audit report**

State verified properties, the unavoidable Cursor bearer-cookie boundary, the lack of App Sandbox, the absent independent audit, the local toolchain limitation, performance measurements, and exact allowed destinations. Copy the report to the projectless chat's `outputs` directory.

- [ ] **Step 4: Commit audit evidence**

Run:

```bash
git add SECURITY-AUDIT.md
git commit -m "docs: record safe fork security audit"
```

- [ ] **Step 5: Create and push the GitHub fork**

Use the authenticated GitHub browser session to create the fork, set `origin` to the user's fork and `upstream` to `vinzdg/codenotch`, then push `audit/safe-local`. Verify the remote commit id matches the local head.

- [ ] **Step 6: Install only after all gates pass**

Copy the verified bundle to `/Applications/Codenotch Safe.app`, launch it, verify its PID resolves to that exact bundle, and repeat signature/entitlement/hash checks against the installed copy.

- [ ] **Step 7: Close the browser task space and report results**

Close the GitHub task space unless user login is still required. Report the fork URL, commit, installed path, measured load, exact remaining risks, and audit artifact.
