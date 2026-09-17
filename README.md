# Codenotch Safe

Codenotch Safe is an audited macOS usage monitor for Claude Code, Cursor, and Codex. It is based on [Codenotch by Vinz](https://github.com/vinzdg/codenotch) and distributed under the [MIT License](LICENSE).

## Install

Download `Codenotch-Safe-1.6.0-safe.13-universal.dmg` from the [GitHub Releases page](https://github.com/x950827/codenotch-safe/releases), or install the checksum-pinned Homebrew Cask:

```sh
brew install --cask x950827/tap/codenotch-safe
```

The app is ad-hoc signed and is not notarized by Apple. If macOS blocks the first launch, open **System Settings → Privacy & Security**, find the Codenotch Safe message, choose **Open Anyway**, and confirm **Open** once. Do not disable Gatekeeper globally.

Requires macOS 15.0 or later. The release contains native `arm64` and `x86_64` executables.

## Choose providers

Open **Settings → Accounts** and switch off tools you do not use. A disabled provider is not queried, its activity monitor is stopped, and its live session rows are cleared. The choice persists across launches.

Safe keeps only these integrations:

- Claude limits from local Claude Code status-line data and the installed Claude CLI, without Keychain or bearer-token reads.
- Codex limits from its local app server, without bearer-token reads.
- Cursor limits from its local editor state and `https://cursor.com/api/usage-summary`, only while Cursor is enabled.

The Safe build contains no embedded web view, analytics, automatic updater, or other provider endpoints. See the [security audit](SECURITY-AUDIT.md) for the checked source and runtime boundaries.

## Build and verify

The local release pipeline builds both architectures, signs the assembled app ad-hoc, verifies its credential and network boundaries, creates the DMG, checks the DMG contents, and renders the Homebrew Cask:

```sh
CODENOTCH_SIGNING_IDENTITY=- make safe-homebrew
```

Xcode is needed only for the XCTest suite (`make test-ci`). The direct audited release build uses the macOS Command Line Tools.

## Attribution and license

Original application: [vinzdg/codenotch](https://github.com/vinzdg/codenotch), created by **Vinz**. Codenotch Safe changes are maintained at [x950827/codenotch-safe](https://github.com/x950827/codenotch-safe). The unmodified upstream copyright and permission notice are bundled inside the application and DMG.

[MIT License](https://github.com/vinzdg/codenotch/blob/main/LICENSE) · [Safe source](https://github.com/x950827/codenotch-safe) · [Security audit](https://github.com/x950827/codenotch-safe/blob/main/SECURITY-AUDIT.md)
