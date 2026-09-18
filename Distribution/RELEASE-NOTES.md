# Codenotch Safe 1.6.0-safe.14

Codenotch Safe is an audited fork of [Codenotch by Vinz](https://github.com/vinzdg/codenotch) for teams that use Claude, Cursor, and Codex. Each provider can be disabled independently; a disabled provider is not queried and its activity monitor is stopped.

Safe.14 discards a Claude five-hour cache after its reset time passes. This prevents an expired percentage from being saved again as a fresh reading and removes the endless `Resetting…` state. Live Claude limits require a fresh Claude Code status-line record or `/usage` output; Codenotch Safe still does not read Claude's Keychain or bearer token.

The release is a universal macOS application for Apple silicon and Intel Macs running macOS 15.0 or later. Install it from the DMG or through the checksum-pinned Homebrew Cask:

```sh
brew install --cask x950827/tap/codenotch-safe
```

The cask verifies the release's pinned SHA-256 checksum and then removes quarantine only from the installed `Codenotch Safe.app`, because the build is ad-hoc signed and is not notarized by Apple. If you install from the DMG instead and macOS blocks its first launch, open **System Settings → Privacy & Security**, find the Codenotch Safe message, choose **Open Anyway**, and confirm **Open** once.

- [Safe source](https://github.com/x950827/codenotch-safe)
- [Security audit](https://github.com/x950827/codenotch-safe/blob/main/SECURITY-AUDIT.md)
- [Original source](https://github.com/vinzdg/codenotch)
- [MIT License](https://github.com/vinzdg/codenotch/blob/main/LICENSE)
