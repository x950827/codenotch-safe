# Codenotch Safe Team Distribution Design

**Date:** 2026-09-17

**Status:** Approved in chat; awaiting written-spec review

**Target release:** `1.6.0-safe.13`

## Context

Codenotch Safe currently builds an audited, Apple-Silicon-only application with either a local certificate or an ad-hoc signature. That is sufficient for a single audited Mac, but it is not a convenient team distribution: the CI artifact is a ZIP, it is not a GitHub Release, there is no Homebrew cask, the system Settings command opens an empty window, and the current author credit does not explain the relationship between Codenotch and the Safe fork.

The organization does not have an Apple Developer Program membership. The release therefore cannot use a Developer ID certificate or Apple notarization. Direct DMG installs require each user to approve the first launch manually. For the team Homebrew path, the cask may remove `com.apple.quarantine` only from the installed application after verifying the pinned release checksum. The release must disclose this behavior and must not change global Gatekeeper settings or conceal the missing notarization.

The upstream project is Codenotch by Vinz. It uses the MIT License, which permits internal and public redistribution and modification provided that the copyright and license notice remain with copies or substantial portions of the software.

## Goals

1. Produce one reproducible release artifact that runs on supported Apple Silicon and Intel Macs.
2. Make it installable either from a GitHub Release or with one Homebrew Cask command.
3. Preserve and visibly disclose the Safe fork's audited credential and network boundaries.
4. Let users enable only Claude, Cursor, and Codex providers that they use.
5. Credit the original author and show exactly what the fork changes, with source, audit, and license links.
6. Fix the system About and Settings menu commands so they open useful Codenotch Safe windows.
7. Preserve the existing bundle identifier and preferences so Safe.12 users can update without losing settings.

## Non-goals

- Apple Developer ID signing or notarization without an organization-owned Apple Developer account.
- Disabling Gatekeeper globally or clearing quarantine from anything except the installed Codenotch Safe bundle.
- Restoring Sparkle or any other in-app updater.
- Publishing to the Mac App Store or the official `homebrew/cask` repository.
- Adding providers beyond Claude, Cursor, and Codex.
- Reading Claude or Codex bearer tokens or restoring a Keychain reader.

## Chosen distribution approach

The release will use an ad-hoc signed universal application packaged in a DMG and published as a GitHub Release. A separate public Homebrew tap will contain a cask that downloads the same immutable DMG and verifies its SHA-256 checksum.

This approach provides a direct download and a one-command installation while keeping the security limitation visible. Both installation paths end with the same application bits. Direct DMG installation uses macOS's supported **Open Anyway** flow. The Homebrew cask verifies the exact SHA-256 and then runs `/usr/bin/xattr -dr com.apple.quarantine` against only `{{appdir}}/Codenotch Safe.app`. It does not change `spctl` or any global security setting.

The two rejected approaches are:

- A Developer ID-signed and notarized release. This gives the best user experience but is unavailable without an Apple Developer Program membership. The release pipeline will keep a clean future upgrade path to this mode.
- Building from source on every teammate's Mac. This avoids distributing an unnotarized binary but requires Xcode or compatible command-line tools and makes installation slower and less reproducible for non-developers.

## Application changes

### Provider selection and lifecycle

The Accounts pane remains the source of truth for which providers are enabled. Claude, Cursor, and Codex each have an independent switch.

Disabling a provider must:

- stop scheduled and manual usage refreshes for that provider;
- stop its activity monitor and clear its live session rows;
- avoid opening, reading, or querying its account source while disabled;
- persist across launches.

Enabling a provider starts its usage provider and activity monitor and performs one refresh. Existing provider order and enabled-state preferences are preserved. A clean install keeps the current default set, then opens Accounts on first launch so the user can turn off tools they do not use.

### About window

The system **About Codenotch Safe** command opens a dedicated About window. It contains:

- application name, icon, version, and build number;
- `Codenotch Safe is based on Codenotch by Vinz.` with a link to `https://github.com/vinzdg/codenotch`;
- `Original Codenotch Copyright (c) 2026 Vinz, licensed under the MIT License.`;
- a link to the Safe fork at `https://github.com/x950827/codenotch-safe`;
- a link to the Safe security audit in the fork;
- a link or button that opens the bundled MIT license;
- a concise list of Safe changes:
  - limits are limited to Claude, Cursor, and Codex;
  - unused providers can be disabled independently;
  - Claude usage comes from the local Claude status-line bridge without a Claude Keychain or bearer-token reader;
  - Codex usage comes from the local Codex app server without reading Codex bearer tokens;
  - only an enabled Cursor provider may contact Cursor's usage endpoint;
  - embedded web views, the upstream updater, analytics, and unrelated network destinations are absent from the Safe build;
  - CI verifies these boundaries for each release.

The wording describes source and runtime boundaries. It must not claim third-party certification or imply that the upstream author endorses the fork.

The application bundle contains `Contents/Resources/LICENSE.txt` with the unmodified upstream MIT text. The DMG also shows a copy of the license at its root. `NSHumanReadableCopyright` carries the upstream copyright in `Info.plist`.

### System application menu

The app replaces the default empty SwiftUI commands with explicit routes:

- **About Codenotch Safe** opens the About window;
- **Settings…** opens the existing custom settings window;
- the keyboard shortcut for Settings remains Command-comma.

The custom notch gear, menu-bar item, Dock menu, and first-launch behavior continue to open the same settings controller.

### Safe copy corrections

Settings and first-launch explanations must match the Safe build. Text that says macOS will ask for a Keychain password or recommends **Always Allow** is removed. The replacement says that Claude and Codex are read through their local integration surfaces, Cursor may use its usage endpoint when enabled, and a disabled provider is not queried.

## Build and packaging architecture

### Universal build

The safe build script compiles the main executable and Claude status-line helper separately for `arm64` and `x86_64`, then combines each pair with `lipo`. Both slices use the same deployment target and source allowlist. The output bundle is named `Codenotch Safe.app`; its executable remains `Codenotch` and its bundle identifier remains `local.audited.codenotch` for preference compatibility.

Release metadata is supplied through one version source rather than repeated literals. The expected release is:

- short version: `1.6.0-safe.13`;
- build number: `13`;
- tag: `v1.6.0-safe.13`.

The CI build is ad-hoc signed after both slices and all resources are assembled. The signature covers the main executable, helper, Info.plist, About resources, and license.

### Verification

The existing verifier remains the release gate and gains checks for:

- both `arm64` and `x86_64` slices in the main executable and helper;
- the expected application name, bundle identifier, version, and build;
- an ad-hoc signature for the public unsigned release mode;
- the bundled license and exact upstream copyright notice;
- About source, fork, audit, and license URLs;
- absence of unexpected entitlements, forbidden frameworks, Keychain reads, bearer-token paths, updater/web-view symbols, and unapproved destinations;
- provider-disable behavior for both usage providers and activity monitors.

The release job fails before publishing if any test or verifier check fails.

### DMG and GitHub Release

The DMG contains:

- `Codenotch Safe.app`;
- an `Applications` shortcut;
- `LICENSE.txt`;
- `FIRST-LAUNCH.txt` with the macOS Open Anyway instructions and links to the source and audit.

The tag workflow builds from the tagged commit, runs unit and boundary tests, creates the DMG, verifies the mounted application, and writes `SHA256SUMS.txt`. It publishes both files to a GitHub Release using GitHub's own CLI and the workflow token. The release notes prominently state that the artifact is ad-hoc signed and not notarized.

The workflow must not read signing identities, Apple credentials, user Keychains, or provider credentials. A later Developer ID release may add a separate signing job without weakening the existing safe verifier.

## Homebrew distribution

The canonical tap is a separate public repository named `x950827/homebrew-tap`. Its `Casks/codenotch-safe.rb` declares:

- the exact Safe version;
- the GitHub Release DMG URL;
- the exact SHA-256 from `SHA256SUMS.txt`;
- the project homepage and description;
- the macOS dependency and supported architecture information;
- `app "Codenotch Safe.app"`;
- a caveat disclosing the app-scoped quarantine removal and checksum verification.

It must not use `sha256 :no_check`, run an installer script, alter `spctl`, or remove quarantine from any path other than `{{appdir}}/Codenotch Safe.app`. Its declarative postflight step must use `/usr/bin/xattr` without `sudo`. Installation is:

```sh
brew install --cask x950827/tap/codenotch-safe
```

The first release prepares and audits the tap locally. Creating the external repository, pushing it, creating the release tag, and publishing the GitHub Release remain explicit remote actions performed only after the corresponding commits and artifacts are ready for review.

## Failure handling

- If either architecture fails to compile, no single-architecture release is silently substituted.
- If the DMG hash differs from the cask hash, Homebrew refuses installation.
- If a release asset already exists, the workflow fails rather than replacing published bytes under the same version.
- If GitHub Release publication succeeds but the tap update fails, direct download remains valid and the Brew instructions stay unpublished until the exact cask is available.
- If Gatekeeper blocks a direct-DMG first launch, documentation points to Apple's Open Anyway UI. Homebrew installation discloses its app-scoped quarantine removal. Neither path recommends disabling Gatekeeper globally.
- If a provider is unavailable or not installed, its row explains that state without requesting a password.

## Testing and acceptance criteria

The implementation is complete when all of the following are demonstrated:

1. Existing unit tests and safe boundary checks pass.
2. New tests prove that a disabled provider neither refreshes usage nor runs its activity monitor.
3. Menu tests prove that About and Settings route to the correct controllers.
4. About tests pin the original author, copyright, source, fork, audit, and license URLs.
5. The built application and helper each contain `arm64` and `x86_64` slices.
6. A mounted DMG contains the application, Applications shortcut, license, and first-launch guide.
7. `codesign --verify --deep --strict` passes for the packaged application.
8. The verifier records and checks the DMG SHA-256.
9. The cask passes `brew style` and `brew audit --cask` against the final release URL and checksum.
10. On a clean macOS account, direct-download and Homebrew installs both place the same application in Applications; the DMG path shows the documented Gatekeeper flow, while the cask path clears only the installed app's quarantine attribute and launches normally.
11. A Safe.12 installation retains its provider choices and display settings after replacing the app with Safe.13.

## Release boundary

Implementation may create code, tests, documentation, packaging scripts, local commits, and a locally validated tap. It does not publish a GitHub Release, create or push the external tap repository, or push new commits until the user reviews the concrete result and authorizes those named remote actions.
