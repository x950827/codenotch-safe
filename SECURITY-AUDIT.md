# Codenotch Safe: local security audit

- Audit date: 2026-09-14
- Upstream base: `vinzdg/codenotch` at `6482ce0`
- Audited implementation commit: `4bf16531b8bb4f7f89524d3a7f7f4924b0a5e323`
- Xcode 26 CI validation: safe.12 [push run #26](https://github.com/x950827/codenotch-safe/actions/runs/34856572971) passed in 3m 14s and [PR run #27](https://github.com/x950827/codenotch-safe/actions/runs/34856578947) passed in 3m 32s
- Audited executable SHA-256: `711843a35331177f063ddd0bc4153c17a89cf6b3407552fdd37d08eae136035b`
- Audited status-line helper SHA-256: `c447e3e6cdb96a92de036f01a1448e6377be89d67912cc9d472741e73660bf21`
- Bundle identifier: `local.audited.codenotch`
- Bundle version: `1.6.0-safe.12`

## Verdict

The safe.12 build passed its local source, binary, signing, destination,
executable-boundary, and parser gates, plus both Xcode 26 CI runs. The exact
audited bundle is installed at `/Applications/Codenotch Safe.app`; strict
signature validation and installed-file hashes match the verified build. The
local app is signed by
`Codenotch Local Signing`; its designated requirement binds the stable
certificate fingerprint to `local.audited.codenotch`.

Safe.11 removed the Claude OAuth fallback and its source file from the safe
target. The installed main executable contains no `SecItemCopyMatching` symbol
or Anthropic OAuth endpoint, so Codenotch cannot present the Claude Code
Keychain access dialog. Safe.12 restores live Claude limits by allowing the
restricted Claude CLI's built-in `/usage` request while keeping separate
auto-update, telemetry, error-reporting, feedback, connector, artifact, and
marketplace guards. Claude now uses only the normalized status-line bridge,
the restricted Claude CLI, and dated local caches. The full 310-second process,
network, CPU, and RSS evidence remains the safe.7 run below.

## Allowed data flows

| Provider | Local access | External action | Persistence in Codenotch |
| --- | --- | --- | --- |
| Claude | Reads the default Claude Code profile's local account label and session-status files. A bundled status-line bridge retains only normalized rate-limit fields. Codenotch does not read Claude's Keychain or OAuth token. | Prefers the bridge record, then runs the restricted `claude --print ... /usage` command. The installed first-party Claude CLI performs its own usage request; there is no Codenotch-owned Claude network request. | Only normalized percentages and reset times from the bridge, CLI, or dated local cache are retained. Raw status-line input and CLI output are never archived or logged. |
| Cursor | Opens Cursor's editor SQLite store read-only and reads the two values needed to form Cursor's session cookie. Activity comes from `composerHeaders` in the same store. | One `GET` to exactly `https://cursor.com/api/usage-summary`; redirects are rejected. | The session is ephemeral: no cookie jar, credential store, URL cache, response body log, or token persistence. Normalized usage is archived. |
| Codex | Reads local activity metadata. Codenotch does not read `auth.json` or a bearer token. | Starts the installed `codex app-server` and sends a fixed three-message JSONL exchange: `initialize`, `initialized`, and `account/rateLimits/read`. | Only normalized primary/secondary windows are archived. Other app-server messages are ignored. |

Anthropic documents `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` as disabling
auto-updates, telemetry, error reporting, release notes, availability checks,
and background plugin command sources. On Claude Code 2.1.267 that umbrella
switch also suppressed the built-in `/usage` network result. Safe.12 leaves it
unset and uses the documented individual `DISABLE_AUTOUPDATER`,
`DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`, and
`DISABLE_FEEDBACK_COMMAND` controls instead. It also keeps
`ENABLE_CLAUDEAI_MCP_SERVERS=false`, `CLAUDE_CODE_DISABLE_ARTIFACT=1`, and
`CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1`:
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
  - `https://cursor.com/dashboard` (user-opened account link)
  - `https://claude.ai/settings/usage` (user-opened account link)
- Undefined-symbol inspection finds no `SecItemCopyMatching`, `SecItemAdd`,
  `SecItemUpdate`, or `SecItemDelete` in either binary. The status-line helper
  has no Keychain or network boundary, and neither binary contains `WKWebView`
  or a Sparkle updater symbol.
- Linked libraries are Apple system frameworks and `libsqlite3`; no third-party
  analytics, crash-reporting, WebView, or updater framework is linked.
- The local safe.12 signature has no entitlements and uses the self-signed
  `Codenotch Local Signing` identity with fingerprint
  `FBDC365911D5BECFEF46AB583120B3A56F282185`. Its designated requirement is
  `identifier "local.audited.codenotch" and certificate leaf =
  H"fbdc365911d5becfef46ab583120b3a56f282185"`.
- GitHub Actions explicitly sets `CODENOTCH_SIGNING_IDENTITY=-`, so CI remains
  reproducible with an ad-hoc artifact and never receives the local private
  key. Local builds require one exact valid identity match and fail if it is
  absent or ambiguous.
- The bundle has no app sandbox and no network client entitlement declaration
  because it is a locally built, unsandboxed macOS app.
- CI actions are pinned to full commit SHAs (`actions/checkout` v4.4.0 and
  `actions/upload-artifact` v7.0.1).

The verifier rejects a provider-ring `repeatForever` animation, automatic
`ClaudeProfile.discover`, unrelated imports/symbols/destination strings,
every Keychain symbol or Security/LocalAuthentication import, every Anthropic
API endpoint, the umbrella environment switch that blocks CLI `/usage`,
unexpected entitlements, an unexpected bundle identifier, and
unrecognized extended attributes. It also executes the bridge against a
privacy fixture and verifies byte-for-byte forwarding, the minimal persisted
schema and mode `0600`. Signing verification records the selected mode,
fingerprint, authorities, and designated requirement. A certificate build must
match the selected leaf fingerprint and must not use a hash-only `cdhash`
requirement; an ad-hoc build must be explicitly requested. Because this
repository is under a File Provider-managed Documents directory, signature
validation runs on a metadata-free staging copy.

## Runtime evidence

### safe.12 live-limit and cold-launch test

The final installed safe.12 bundle was stopped and launched from a state with
no `SecurityAgent` or `authorizationhost` process. A continuous 20-second
process monitor observed no authentication agent. The surviving process was
PID 4984 at the exact installed executable path.

At 10:54:43 UTC the installed app archived a fresh Claude CLI reading with a
19% current-session window and a 4% all-models weekly window. Codex and Cursor
also refreshed on the same launch. The live accessibility tree displayed the
three rings as `19% 34% 16%`, with Claude first. Installed-binary inspection
found no `SecItemCopyMatching` or legacy `SecKeychain` symbol, strict deep
signature verification passed, and installed hashes matched the verified
safe.12 build. The preceding safe.11 bundle is preserved at
`/Applications/Codenotch Safe.app.safe11-rollback`.

An independent invocation of Claude Code 2.1.267 reproduced the cause. With
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, `/usage` returned only local
contribution statistics and no limit windows. With the umbrella switch absent
and the four individual privacy/update controls enabled, the same restricted
command returned the live 19% session and 4% weekly limits without a Keychain
dialog.

### safe.11 Keychain-free cold-launch test

The then-installed safe.11 bundle passed strict deep signature verification at its final
`/Applications` path. Its executable and helper hashes matched the verified
build. Safe.10 remains available at
`/Applications/Codenotch Safe.app.safe10-rollback`.

The final installed build was stopped and launched from a state with no
`SecurityAgent` or `authorizationhost` process. A 40-second continuous process
monitor observed no authentication agent. The only matching application after
the run was PID 54163 at the exact installed Codenotch executable path. An
earlier safe.11 build passed the same cold-launch monitor independently.

The first and next scheduled refresh both completed promptly. Claude returned
`needsAuth` at 10:14:22 UTC and again at 10:19:22 without any `refresh skipped`
event. Codex advanced to 10:19:23 and Cursor to 10:19:22. System logs after the
final cold-launch boundary contained no SecurityAgent or authorizationhost
event, and the current process list contained only the installed Codenotch
executable. Installed-binary inspection confirmed that `SecItemCopyMatching`
is absent.

### safe.9 and safe.10 invalidation evidence

The previously recorded safe.9 short smoke was insufficient. A user cold
restart on 2026-09-14 produced the Claude Code Keychain password dialog.
System logs tied SecurityAgent to the restarted Codenotch process, and the
previous PID logged
`refresh skipped: one already in flight` every five minutes until the blocked
query ended.

Safe.10 added `kSecUseAuthenticationUISkip` alongside the non-interactive
`LAContext`, but the same clean monitor observed SecurityAgent 2.4 seconds after
launch. That build was rejected. Safe.11 removes the Keychain path instead of
trying to control the legacy Keychain ACL dialog.

### safe.8 post-install smoke

The installed bundle passed strict deep signature verification at its final
`/Applications` path. Its executable and helper hashes matched the verified
build, and its designated requirement matched the requirement above. The
previous safe.7 installation is preserved at
`/Applications/Codenotch Safe.app.safe7-rollback`.

The archived normalized readings advanced after the safe.8 launch:

| Provider | Before (UTC) | After (UTC) | Observed normalized reading |
| --- | --- | --- | --- |
| Claude | 2026-09-11 16:28:58 | 2026-09-11 16:34:20 | session 7%, weekly 42% |
| Codex | 2026-09-11 16:29:01 | 2026-09-11 16:34:22 | primary 80% |
| Cursor | 2026-09-11 16:28:59 | 2026-09-11 16:34:21 | auto 32.29%, API 41.36% |

After refresh, PID 53000 was the exact installed executable and had no child
process. Its two established connections were the previously audited Anthropic
destination `160.79.104.10:443` and the machine's `198.18.0.0/15` TUN path.
This short smoke confirms successful post-install refresh; it does not replace
the longer boundary and performance run.

### Full safe.7 boundary and performance run

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
   through print mode on this machine. Safe.11 no longer compensates by reading
   OAuth credentials; it degrades to a dated cache or `needsAuth`.
7. Service-only Keychain discovery could select a credential belonging to a
   different Claude Code account record. An intermediate implementation matched
   Claude Code's service-plus-current-user rule, but safe.11 removes that query
   and the complete safe OAuth reader.
8. Ad-hoc signing gave every rebuild a hash-only designated requirement, so a
   Keychain access decision could not follow the app across builds. Local
   builds still resolve one exact valid certificate fingerprint and verify the
   certificate-backed designated requirement for bundle integrity. CI requests
   ad-hoc signing explicitly because it has no access to the private key.
9. A background Claude OAuth fallback could call `SecItemCopyMatching` without
   disabling authentication UI. When a rotated credential required approval,
   the password dialog blocked the refresh actor and every later timer tick was
   skipped as already in flight. Safe.9's non-interactive `LAContext` and
   safe.10's additional `kSecUseAuthenticationUISkip` both failed to suppress
   the legacy ACL dialog on the tested macOS build. Safe.11 deletes the OAuth
   reader and makes the verifier reject every Keychain symbol in the safe
   binaries.

## Residual trust and limitations

- The app is unsandboxed so it can read Cursor's local SQLite store and local
  Claude/Codex activity. A compromise of this process could access data allowed
  to the current macOS user.
- The Cursor session cookie is sensitive. The app holds it briefly in memory
  and sends it to Cursor's exact usage endpoint; it cannot offer hardware-backed
  isolation for that value.
- Claude can show a dated reading or `needsAuth` when neither the status-line
  bridge nor restricted CLI returns usage windows. Codenotch cannot compensate
  with the OAuth endpoint because the safe target has no Claude credential
  access.
- Claude Code and Codex are external executables. Their code, authentication,
  and vendor-side behavior are outside this repository. The Claude invocation
  disables specific documented update, telemetry, error-reporting, feedback,
  connector, artifact, and marketplace behaviors; it must leave the broader
  nonessential-traffic switch unset for `/usage`. A CLI update requires a new
  runtime check.
- The installed app uses a locally trusted self-signed certificate. It is not
  Developer ID-signed or notarized and is suitable only for this machine's
  local installation, not redistribution as a publicly trusted binary. The CI
  artifact remains ad-hoc signed.
- Local verification used the available Command Line Tools compiler with the
  compatible macOS 15.4 SDK and deployment target 15.0, then ran the app on
  macOS 26.5.1. The checked-in XcodeGen project targets macOS 26.
- XcodeGen 2.46.0 is installed locally, but the machine has Command Line Tools
  rather than full Xcode/XCTest, so `xcodebuild` cannot run the XCTest target.
  Pinned `macos-26` Safe CI run #22 ran the full XCTest target, rebuilt safe.11
  with the explicit ad-hoc CI mode, passed the strengthened verifier, and
  uploaded the packaged app. Local source
  type-check, optimized build, certificate signing, signing-selection fixtures,
  static verifier, bridge fixture, request/parser harness, installed-bundle
  validation, and normalized live-read check passed for safe.12. Safe.12's
  push and pull-request CI runs both ran the full XCTest target, rebuilt and
  verified the audited app, packaged it, and uploaded the artifact successfully.
- This is a focused engineering audit, not an independent third-party security
  assessment or a formal proof of non-exfiltration.

## Reproduction

```sh
make safe-verify
```

This local command requires the exact valid `Codenotch Local Signing` identity.
It type-checks the allowlisted source, tests identity selection and the
Keychain-free Claude policy, produces the
optimized app, verifies its certificate leaf, designated requirement,
entitlements, imports, symbols, destinations, bundle metadata, and xattrs, and
records the evidence under `build/safe/verification/`.

CI uses the explicit ad-hoc equivalent:

```sh
CODENOTCH_SIGNING_IDENTITY=- make safe-verify
```
