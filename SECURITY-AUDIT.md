# Codenotch Safe: local security audit

Audit date: 2026-09-09  
Upstream base: `vinzdg/codenotch` at `6482ce0`  
Audited implementation commit: `e153661919afd4e53551da40d5ee620a77fee242`  
Xcode 26 CI validation: Safe CI [run #12](https://github.com/x950827/codenotch-safe/actions/runs/34368730509) passed in 3m 5s  
Audited executable SHA-256: `f153d2502732c4b8e7ad0b80aaef46001fcaafab29a0896b64c33a0d71c9a11c`  
Audited status-line helper SHA-256: `808a116e07e6dbd51b580ca87c95bfdb173ea5ed514e478cf9a69b68fab8cfae`  
Bundle identifier: `local.audited.codenotch`  
Bundle version: `1.6.0-safe.7`

## Verdict

The safe.7 build passed its local source, binary, signing, destination,
executable-boundary, parser, and Xcode 26 CI gates. The exact audited bundle is
installed at `/Applications/Codenotch Safe.app`; strict signature validation
and installed-file hashes match the verified build.

Live validation completed after the user authorized read-only Keychain access
and refreshed an expired Claude Code OAuth session with the official
`claude auth login` flow. Codenotch then fetched and archived fresh normalized
Claude and Codex limits. A 310-second run of that installed binary met the idle
CPU and RSS gates and showed only the two expected CLI children.

## Allowed data flows

| Provider | Local access | External action | Persistence in Codenotch |
| --- | --- | --- | --- |
| Claude | Reads the default Claude Code profile's local account label and session-status files. A bundled status-line bridge retains only normalized rate-limit fields. If both local live sources fail, one audited Swift file selects the newest item matching both the exact default Claude Code credential service and current-user account, then decodes only `accessToken` and `expiresAt`. | Prefers the bridge record, then runs the restricted `claude --print ... /usage` command. The final fallback sends one `GET` to exactly `https://api.anthropic.com/api/oauth/usage`; redirects, cookies, URL credentials, caches and connection proxy overrides are disabled. | The OAuth token is held only in memory until expiry. Only normalized percentages and reset times are archived; raw status-line input, CLI output, Keychain data and response bodies are never stored or logged. Diagnostic messages name only the failed stage, field path, or fixed validation category. |
| Cursor | Opens Cursor's editor SQLite store read-only and reads the two values needed to form Cursor's session cookie. Activity comes from `composerHeaders` in the same store. | One `GET` to exactly `https://cursor.com/api/usage-summary`; redirects are rejected. | The session is ephemeral: no cookie jar, credential store, URL cache, response body log, or token persistence. Normalized usage is archived. |
| Codex | Reads local activity metadata. Codenotch does not read `auth.json` or a bearer token. | Starts the installed `codex app-server` and sends a fixed three-message JSONL exchange: `initialize`, `initialized`, and `account/rateLimits/read`. | Only normalized primary/secondary windows are archived. Other app-server messages are ignored. |

Anthropic documents `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` as disabling
auto-updates, telemetry, error reporting, release notes, availability checks,
and background plugin command sources. It separately documents
`ENABLE_CLAUDEAI_MCP_SERVERS=false` for disabling hosted connectors and
`CLAUDE_CODE_DISABLE_ARTIFACT=1` for disabling artifact publishing:
[Claude Code environment variables](https://code.claude.com/docs/en/env-vars).

## Compiled surface

- `project.yml` excludes the complete upstream `Sources/Providers` directory,
  then adds only nine audited provider support files. `Scripts/safe-source-list.sh`
  applies the same allowlist to the local compiler.
- The app registers only the default Claude profile, Cursor, and Codex. Other
  provider implementations remain in the repository for upstream traceability,
  but are absent from the target and local safe build.
- Static binary URL extraction includes only these app-owned requests:
  - `https://cursor.com/api/usage-summary` (the app-owned request)
  - `https://api.anthropic.com/api/oauth/usage` (the audited Claude fallback)
  - `https://cursor.com/dashboard` (user-opened account link)
  - `https://claude.ai/settings/usage` (user-opened account link)
- Undefined-symbol inspection finds `SecItemCopyMatching` only in the main app.
  The status-line helper has no Keychain or network boundary, and neither binary
  contains `SecItemAdd`, `SecItemUpdate`, `SecItemDelete`, `WKWebView`, or a
  Sparkle updater symbol.
- Linked libraries are Apple system frameworks and `libsqlite3`; no third-party
  analytics, crash-reporting, WebView, or updater framework is linked.
- The ad-hoc signature has no entitlements. The bundle has no app sandbox and
  no network client entitlement declaration because it is a locally built,
  unsandboxed macOS app.
- CI actions are pinned to full commit SHAs (`actions/checkout` v4.4.0 and
  `actions/upload-artifact` v7.0.1).

The verifier rejects a provider-ring `repeatForever` animation, automatic
`ClaudeProfile.discover`, unrelated imports/symbols/destination strings,
Keychain mutation symbols, an Anthropic endpoint other than the single literal
above, unexpected entitlements, an unexpected bundle identifier, and
unrecognized extended attributes. It also executes the bridge against a
privacy fixture and verifies byte-for-byte forwarding, the minimal persisted
schema and mode `0600`. Because this repository is under a File Provider-managed
Documents directory, signature validation runs on a metadata-free staging copy.

## Runtime evidence (safe.7)

Final run: macOS 26.5.1, 310.095 seconds, 63 resource samples at five-second
intervals, process/socket probes at one-second intervals with no probe failures.
PID 96886 was validated before and throughout the run as the exact installed
executable `/Applications/Codenotch Safe.app/Contents/MacOS/Codenotch`.

| Metric | Result | Gate |
| --- | ---: | ---: |
| Main-process CPU, median | 0.400% | < 1% idle target |
| Main-process CPU, settled average (final 135 seconds) | 0.479% | < 1% idle target |
| Main-process CPU, full-run average | 1.851% | Informational; includes refresh-related spikes |
| Main-process CPU, brief maximum | 18.000% | Informational; refresh burst |
| Main-process RSS, average | 55.826 MB | < 100 MB target |
| Main-process RSS, maximum | 81.688 MB | < 100 MB target |

The process tree contained only Codenotch, Claude Code 2.1.266, and the installed
ChatGPT `codex` binary. Claude Code and Codenotch were both observed connecting
to `160.79.104.10:443` during the Claude refresh; the source and executable gates
restrict Codenotch's direct request to the exact Anthropic usage URL above.
Codenotch and Codex also used the machine's `198.18.0.0/15` TUN path. No MCP,
Node, SSH, browser, updater, or other child process appeared in the run.

The refresh at 49-52 seconds produced fresh persisted readings without retaining
credentials or response bodies: Claude recorded session 17% and weekly 23% at
2026-09-09 15:49:46 UTC with future reset times; Codex recorded primary 27% at
15:49:48 UTC with a future reset time. These values changed from the pre-run
readings (Claude session 16%, Codex primary 26%), proving that the installed app
completed new reads during the monitored cycle rather than merely replaying its
archive.

The one-second socket probe can miss a connection that starts and ends between
samples. The runtime evidence is therefore paired with exact request builders,
source allowlists, executable string/symbol scans, and isolated CLI probes. It
is evidence of the tested run, not a system-wide firewall.

## Problems found and fixed during the audit

1. Continuous SwiftUI activity animations kept an active-agent display near
   6% CPU. The indicators are now static while the underlying activity still
   refreshes every five seconds.
2. Automatic `~/.claude-*` discovery executed arbitrary per-profile helpers;
   the first runtime probe observed MCP and SSH descendants. The safe build now
   uses only the default profile and Claude's customization-free CLI flags.
3. A five-minute timer could see 299.9 seconds at the exact boundary and skip
   until minute ten. A one-second boundary tolerance fixes the missed tick
   without allowing requests more often than the five-minute timer.
4. File Provider could reattach FinderInfo between signing and verification.
   The verifier now rejects unknown xattrs and validates the unchanged signed
   contents in a temporary non-File-Provider staging directory.
5. Concurrent, long-lived Claude sessions kept overwriting a shared status-line
   value with expired windows. The bridge now rejects an expired five-hour reset,
   and the provider accepts the record as live for at most five minutes.
6. Current Claude Code releases did not expose the user's live `/usage` screen
   through print mode on this machine. The safe.7 fallback confines direct OAuth
   access to one source file, two exact credential service names, read-only
   Keychain calls, an ephemeral session, and one exact Anthropic endpoint.
7. Service-only Keychain discovery could select a credential belonging to a
   different Claude Code account record. The final query matches Claude Code's
   own service-plus-current-user rule. Fixed, non-secret diagnostics distinguish
   a missing item, Keychain denial, malformed field, empty token, unsafe token,
   invalid expiry, and expired credential without logging credential values.

## Residual trust and limitations

- The app is unsandboxed so it can read Cursor's local SQLite store and local
  Claude/Codex activity. A compromise of this process could access data allowed
  to the current macOS user.
- The Cursor session cookie is sensitive. The app holds it briefly in memory
  and sends it to Cursor's exact usage endpoint; it cannot offer hardware-backed
  isolation for that value.
- The Claude OAuth access token is also sensitive. The app reads the newest
  matching Claude Code Keychain item, holds only the decoded access token and
  expiry in memory, and sends the token only to the exact Anthropic usage URL.
  macOS may ask the user to grant access to that item.
- Anthropic's OAuth usage endpoint is used by Claude Code but is not a published
  public API contract, so a server-side schema or policy change can disable the
  fallback until this audit is updated.
- Claude Code and Codex are external executables. Their code, authentication,
  and vendor-side behavior are outside this repository. The Claude invocation
  suppresses documented nonessential traffic, and the final run showed only an
  Anthropic-owned destination, but a CLI update requires a new runtime check.
- The app is ad-hoc signed and is not Developer ID-signed or notarized. It is
  suitable for this local installation, not redistribution as a trusted public
  binary.
- Local verification used the available Command Line Tools compiler with the
  compatible macOS 15.4 SDK and deployment target 15.0, then ran the app on
  macOS 26.5.1. The checked-in XcodeGen project targets macOS 26.
- The full XCTest target cannot run locally because full Xcode/XCTest and
  XcodeGen are not installed. Pinned `macos-26` Safe CI run #12 ran the full
  XCTest target, rebuilt the safe.7 bundle, passed `safe-verify`, and uploaded
  the packaged app. Local source type-check, optimized build, signing, static
  verifier, bridge fixture, request/parser harness, installed-bundle validation,
  normalized live-read check, and final runtime gate passed.
- This is a focused engineering audit, not an independent third-party security
  assessment or a formal proof of non-exfiltration.

## Reproduction

```sh
make safe-verify
```

This type-checks the allowlisted source, produces the optimized local app,
verifies its signature and entitlements, scans its imports/symbols/destination
strings, checks its bundle identifier and xattrs, and records the executable
SHA-256 under `build/safe/verification/`.
