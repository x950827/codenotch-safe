# Codenotch Safe 1.6.0-safe.15

Codenotch Safe is an audited fork of [Codenotch by Vinz](https://github.com/vinzdg/codenotch) for teams that use Claude, Cursor, Codex, and OpenCode Go. Each provider can be disabled independently; a disabled provider is not queried and its activity monitor is stopped.

Safe.15 adds an audited OpenCode Go subscription check. The `opencode-go` key is read from `~/.local/share/opencode/auth.json` on every refresh and sent as `Authorization: Bearer` to a single `GET` of `https://opencode.ai/zen/go/v1/usage`. The session is ephemeral (no cookie storage, no URL credential storage, no response cache), the request rejects every redirect to a non-audited host, and the response URL is re-validated against the exact allowlist. A 401 reads as `needsAuth`, a 403 reads as `nothingMetered` (a valid key without a Go plan is metering nothing, which is not an error), and a 429 backs off on a 60-second floor that doubles per consecutive limit and caps at 15 minutes. The deadline is persisted through `UsageArchive` so a relaunch during a penalty waits rather than walking back into the limit.

The release is a universal macOS application for Apple silicon and Intel Macs running macOS 15.0 or later. Install it from the DMG or through the checksum-pinned Homebrew Cask:

```sh
brew install --cask x950827/tap/codenotch-safe
```

The cask verifies the release's pinned SHA-256 checksum and then removes quarantine only from the installed `Codenotch Safe.app`, because the build is ad-hoc signed and is not notarized by Apple. If you install from the DMG instead and macOS blocks its first launch, open **System Settings → Privacy & Security**, find the Codenotch Safe message, choose **Open Anyway**, and confirm **Open** once.

- [Safe source](https://github.com/x950827/codenotch-safe)
- [Security audit](https://github.com/x950827/codenotch-safe/blob/main/SECURITY-AUDIT.md)
- [Original source](https://github.com/vinzdg/codenotch)
- [MIT License](https://github.com/vinzdg/codenotch/blob/main/LICENSE)
