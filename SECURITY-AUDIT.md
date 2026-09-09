# Codenotch Safe: local security audit

Audit date: 2026-09-08  
Upstream base: `vinzdg/codenotch` at `6482ce0`  
Audited implementation commit: `cf3156c37d1f8d5c2ecd03ebe6dbdcec3fa79e73`  
Xcode 26 CI validation commit: `358430893c9693baf0be6f32f7afc645f2930389`
Audited executable SHA-256: `e4d0baabd6c406311faebd126b99efd3ea69bbc1d60eccc66d10da8485e35fd3`  
Bundle identifier: `local.audited.codenotch`  
Bundle version: `1.6.0-safe.1`

## Verdict

The hardened build passed its source, binary, signing, destination, and runtime
gates. During the final 310-second run, no analytics SDK, updater, WebView,
automatic Claude profile, MCP server, Node helper, SSH process, or unrelated
provider endpoint was present in the compiled app or observed in its process
tree.

This verdict applies to the audited source allowlist and the local versions of
Claude Code and Codex used for the test. The app deliberately delegates Claude
and Codex authentication to those installed CLIs, so their future versions are
a trust boundary and should be rechecked after an update.

## Allowed data flows

| Provider | Local access | External action | Persistence in Codenotch |
| --- | --- | --- | --- |
| Claude | Reads the default Claude Code profile's local account label and session-status files. Codenotch does not read a Claude token or keychain item. | Runs only `claude --print --safe-mode --strict-mcp-config --tools "" --no-chrome --no-session-persistence /usage`. The environment drops inherited credentials, alternate API origins, proxies, and hooks; it also disables nonessential traffic, claude.ai connectors, artifacts, and marketplace auto-install. Claude Code itself reads its login and contacts Anthropic. | Normalized percentages and reset times only. No CLI output, token, or response body is stored or logged. |
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
- Static binary URL extraction found only:
  - `https://cursor.com/api/usage-summary` (the app-owned request)
  - `https://cursor.com/dashboard` (user-opened account link)
  - `https://claude.ai/settings/usage` (user-opened account link)
- Undefined-symbol inspection found `NSURLSession` and `sqlite3_open_v2`, with
  no `SecItemCopyMatching`, `WKWebView`, or Sparkle updater symbols.
- Linked libraries are Apple system frameworks and `libsqlite3`; no third-party
  analytics, crash-reporting, WebView, or updater framework is linked.
- The ad-hoc signature has no entitlements. The bundle has no app sandbox and
  no network client entitlement declaration because it is a locally built,
  unsandboxed macOS app.
- CI actions are pinned to full commit SHAs (`actions/checkout` v4.4.0 and
  `actions/upload-artifact` v7.0.1).

The verifier rejects a provider-ring `repeatForever` animation, automatic
`ClaudeProfile.discover`, forbidden imports/symbols/destination strings,
unexpected entitlements, an unexpected bundle identifier, and unrecognized
extended attributes. Because this repository is under a File Provider-managed
Documents directory, signature validation runs on a metadata-free staging copy
after the original bundle's xattrs have been restricted to FinderInfo, File
Provider metadata, and provenance.

## Runtime evidence

Final run: macOS 26.5.1, 310.124 seconds, 63 resource samples at five-second
intervals, process/socket probes at one-second intervals. The monitored PID was
validated against the exact executable path before sampling.

| Metric | Result | Gate |
| --- | ---: | ---: |
| Main-process CPU, average | 0.660% | < 1% idle target |
| Main-process CPU, median | 0.300% | < 1% idle target |
| Main-process CPU, brief maximum | 4.300% | Informational; occurred around refresh |
| Main-process RSS, average | 66.991 MB | < 100 MB target |
| Main-process RSS, maximum | 69.266 MB | < 100 MB target |

The final process tree contained Codenotch, Claude Code 2.1.252, and `codex`.
Claude's observed TCP connection terminated at `160.79.104.10:443`, an address
in Anthropic's AS399358. Codenotch's own observed socket was translated through
the machine's `198.18.0.0/15` TUN path; the executable and request-construction
tests restrict that request to the exact Cursor URL above. No MCP, Node, SSH, or
other child network process appeared in the final run.

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

## Residual trust and limitations

- The app is unsandboxed so it can read Cursor's local SQLite store and local
  Claude/Codex activity. A compromise of this process could access data allowed
  to the current macOS user.
- The Cursor session cookie is sensitive. The app holds it briefly in memory
  and sends it to Cursor's exact usage endpoint; it cannot offer hardware-backed
  isolation for that value.
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
- The full XCTest target could not run locally because full Xcode/XCTest and
  XcodeGen are not installed. The pinned `macos-26` GitHub Actions workflow ran
  the full XCTest target, rebuilt the audited bundle, passed `safe-verify`, and
  uploaded the packaged app. Local source type-check, optimized build, signing,
  static verifier, isolated provider probes, and the final runtime gate also
  passed.
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
