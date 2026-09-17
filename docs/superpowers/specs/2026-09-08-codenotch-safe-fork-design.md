# Codenotch Safe Fork Design

## Goal

Build a locally controlled macOS usage notch for Claude Code, Codex, and Cursor.
The Codenotch process must not send credentials or usage data to the original
maintainer, analytics services, update servers, or unrelated AI providers.

The unavoidable vendor traffic is limited to the software that owns each
session:

- `claude /usage` contacts Anthropic using Claude Code's own session.
- `codex app-server` contacts OpenAI using Codex's own session.
- Codenotch sends one authenticated request to
  `https://cursor.com/api/usage-summary` because Cursor exposes no local
  read-only usage command.

## Trust boundary

Codenotch itself never reads Claude or Codex bearer tokens. It invokes the
installed vendor CLIs with fixed arguments and parses only their usage output.
For Cursor, the app opens Cursor's local SQLite database read-only, constructs
the cookie required by Cursor's usage endpoint in memory, sends it only to the
exact HTTPS origin above, and immediately releases it.

The Cursor request uses an ephemeral `URLSession`, rejects redirects, accepts
only the exact scheme, host, port, and path, and does not use shared cookie,
credential, URL-cache, or proxy state. No response body, token, cookie, account
identifier, local path, or session title is written to logs.

## Compiled scope

The macOS target contains only the three provider paths and their local activity
monitors. It excludes the upstream implementations for Antigravity, Gemini,
GLM, Grok, OpenCode, GitHub Copilot, Perplexity/WebView sessions, credential
discovery for those services, and the `CODENOTCH_DISCOVER` inspection hook.

Sparkle and the `hivinz.com` appcast are removed. The fork has no background
updater and no author-site link. Updates are rebuilt from reviewed source.

The app remains outside App Sandbox because Cursor's database, Codex activity
state, and Claude session files live in other applications' data directories.
Its code signature has no entitlements and it does not request Accessibility,
Screen Recording, Contacts, Calendar, microphone, camera, or browser-data
permissions.

## Local persistence

UserDefaults contains only display preferences, provider enablement, normalized
usage percentages, reset timestamps, and rate-limit backoff deadlines. No raw
provider response or credential is persisted. Turning a provider off removes
its cached normalized reading.

Launch-at-login remains optional and uses `SMAppService.mainApp`; it does not add
a shell script or LaunchAgent.

## Performance budget

- Usage refresh: once on launch, every five minutes, and on explicit manual
  refresh. Busy-agent state does not increase the network or CLI rate.
- Claude and Codex subprocesses: at most one invocation each per five-minute
  refresh; each has a 20-second hard timeout and is terminated after a response.
- Cursor and Codex activity probes: every five seconds, read-only, one-row local
  database queries. Claude activity uses filesystem events plus a five-second
  process-liveness check.
- Idle CPU target: below 1% averaged over five minutes.
- Resident-memory target: below 100 MB after the initial UI settles.
- Network target: no Codenotch-owned connection except the exact Cursor usage
  endpoint. Claude and Codex connections belong to their short-lived CLIs.

If the measured build misses either CPU or memory target, it is not installed
until the cause is fixed or the user explicitly accepts the measured cost.

## Failure behavior

Missing CLI, signed-out state, timeout, malformed output, blocked Cursor access,
or network failure produces a visible stale/auth/error state. The app never
falls back from a failed CLI to reading a token. It never follows a redirect,
loosens the endpoint allowlist, or invents a usage number.

The user's Codex wrapper may refuse to start while the configured sing-box proxy
is down. Codenotch preserves that behavior and shows stale Codex limits instead
of bypassing the wrapper or contacting OpenAI directly.

## Verification

Automated tests cover fixed subprocess arguments, JSONL handshake and parsing
for `account/rateLimits/read`, timeouts, Cursor endpoint validation, redirect
rejection, response parsing, and the absence of raw-body logging.

The release check builds from the reviewed commit, ad-hoc signs the local app,
and verifies:

1. all tests and Swift type checks pass;
2. `codesign --verify --deep --strict` succeeds;
3. the entitlement set is empty;
4. binary strings contain no upstream update/analytics/unrelated-provider hosts;
5. a runtime network trace contains only the allowed Cursor request plus the
   independently executed Claude and Codex CLI processes;
6. idle RSS and CPU remain within the performance budget.

The audit report records the exact commit, build hash, compiled source list,
allowed destinations, test results, signature output, and any verification that
could not be performed locally.
