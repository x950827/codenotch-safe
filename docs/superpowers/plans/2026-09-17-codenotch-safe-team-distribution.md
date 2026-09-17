# Codenotch Safe Team Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Codenotch Safe 1.6.0-safe.13 as an audited universal macOS app with clear upstream attribution, a GitHub Release DMG, and a checksum-pinned Homebrew Cask.

**Architecture:** Keep the existing three-provider Safe runtime and add one coordinator that applies provider enablement to activity monitors as well as usage fetches. Add focused About/menu components, then extend the existing direct Swift compiler build into a two-architecture bundle that is verified before packaging. GitHub Releases and the separate Homebrew tap consume the same immutable DMG; remote publication remains a final approval-gated step.

**Tech Stack:** Swift 5, SwiftUI, AppKit, Combine, XCTest, zsh, `swiftc`, `lipo`, `codesign`, `hdiutil`, GitHub Actions, GitHub CLI, Homebrew Cask.

**Spec:** `docs/superpowers/specs/2026-09-17-codenotch-safe-team-distribution-design.md`

## Global Constraints

- Release version is `1.6.0-safe.13`, build number `13`, and tag `v1.6.0-safe.13`.
- The application bundle is `Codenotch Safe.app`; the executable remains `Codenotch` and the bundle identifier remains `local.audited.codenotch`.
- The minimum supported system is macOS 15.0 (Sequoia), matching the Homebrew cask declaration.
- The release contains both `arm64` and `x86_64` slices or fails; no single-architecture fallback is allowed.
- The organization has no Apple Developer Program membership, so the release is ad-hoc signed and explicitly described as not notarized.
- Do not clear quarantine, change Gatekeeper, use `sha256 :no_check`, or hide the first-launch approval step.
- Keep only Claude, Cursor, and Codex. Disabled providers must not fetch usage, read their account source, or run an activity monitor.
- Do not add Claude or Codex bearer-token reads, Keychain reads in the main app or helper, embedded web views, analytics, or an updater.
- Only an enabled Cursor provider may contact `https://cursor.com/api/usage-summary`.
- Bundle the unmodified MIT license and retain `Copyright (c) 2026 Vinz`.
- Do not publish, push, merge, tag, create the external tap repository, or create a GitHub Release until the user reviews the finished local result and authorizes the named remote actions.

## File Structure

- `Sources/Sessions/ProviderActivityController.swift`: owns start/stop state for provider activity monitors.
- `Sources/App/AppMenuActions.swift`: testable actions used by SwiftUI application commands.
- `Sources/App/CodenotchCommands.swift`: replaces the default About and Settings commands.
- `Sources/About/AboutMetadata.swift`: canonical attribution, URLs, disclosures, and Safe change descriptions.
- `Sources/About/AboutView.swift`: renders the About content without owning window behavior.
- `Sources/About/AboutWindowController.swift`: owns and surfaces the AppKit About window and bundled-license action.
- `Sources/Resources/LICENSE.txt`: verbatim copy of the upstream MIT license included in Xcode and direct builds.
- `Distribution/FIRST-LAUNCH.txt`: Gatekeeper instructions bundled at the DMG root.
- `Distribution/RELEASE-NOTES.md`: disclosure used by the GitHub Release workflow.
- `Distribution/Casks/codenotch-safe.rb.in`: checksum/version template for the external tap.
- `Scripts/safe-release-metadata.sh`: reads version/build metadata from `project.yml`, the single release-version source.
- `Scripts/package-safe-release.sh`: constructs the DMG and checksum file from the verified app.
- `Scripts/verify-safe-release.sh`: mounts and verifies the packaged DMG.
- `Scripts/render-homebrew-cask.sh`: renders a checksum-pinned cask into `build/homebrew-tap`.
- `Scripts/test-safe-release-metadata.sh`: checks version parsing and tag matching.
- `Scripts/test-safe-packaging-policy.sh`: checks DMG and cask policy without weakening Gatekeeper.
- `Scripts/test-safe-release-workflow.sh`: pins release-workflow permissions and no-clobber behavior.
- `.github/workflows/release.yml`: publishes already-verified files when the exact release tag is pushed.
- `SafeTests/SecurityBoundaryTests.swift`: provider lifecycle, menu routing, attribution, URL, and disclosure tests.

---

### Task 1: Stop disabled providers' activity monitors

**Files:**
- Create: `Sources/Sessions/ProviderActivityController.swift`
- Modify: `Sources/App/AppDelegate.swift:8-220`
- Test: `SafeTests/SecurityBoundaryTests.swift`

**Interfaces:**
- Consumes: `[String: any AgentActivityMonitor]`, `Set<String>` disconnected provider IDs.
- Produces: `ProviderActivityController.init(monitors:disconnected:onSessions:)` and `apply(disconnected:)`.
- Produces: `onSessions(providerID, sessions)` for every monitor emission and an empty array when a provider is disabled.

- [ ] **Step 1: Write the failing activity-lifecycle tests**

Append a `@MainActor` spy and tests to `SafeTests/SecurityBoundaryTests.swift`:

```swift
import Combine

@MainActor
private final class ActivityMonitorSpy: AgentActivityMonitor {
    private let subject = CurrentValueSubject<[AgentSession], Never>([])
    var sessions: [AgentSession] { subject.value }
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> {
        subject.eraseToAnyPublisher()
    }
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func send(_ sessions: [AgentSession]) { subject.send(sessions) }
}

@MainActor
final class ProviderActivityControllerTests: XCTestCase {
    func testDisconnectedMonitorDoesNotStartAndReconnectIsIdempotent() {
        let cursor = ActivityMonitorSpy()
        let controller = ProviderActivityController(
            monitors: ["cursor": cursor],
            disconnected: ["cursor"],
            onSessions: { _, _ in }
        )

        XCTAssertEqual(cursor.startCount, 0)
        controller.apply(disconnected: [])
        controller.apply(disconnected: [])
        XCTAssertEqual(cursor.startCount, 1)
    }

    func testDisconnectStopsMonitorAndClearsItsSessions() {
        let cursor = ActivityMonitorSpy()
        var deliveries: [(String, [AgentSession])] = []
        let controller = ProviderActivityController(
            monitors: ["cursor": cursor],
            disconnected: [],
            onSessions: { deliveries.append(($0, $1)) }
        )

        controller.apply(disconnected: ["cursor"])

        XCTAssertEqual(cursor.stopCount, 1)
        XCTAssertEqual(deliveries.last?.0, "cursor")
        XCTAssertTrue(deliveries.last?.1.isEmpty == true)
    }
}
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
make gen
xcodebuild -project Codenotch.xcodeproj -scheme Codenotch -destination 'platform=macOS,arch=arm64' -configuration Debug test CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:CodenotchTests/ProviderActivityControllerTests
```

Expected: compilation fails because `ProviderActivityController` does not exist.

- [ ] **Step 3: Implement the monitor coordinator**

Create `Sources/Sessions/ProviderActivityController.swift`:

```swift
import Combine

@MainActor
final class ProviderActivityController {
    typealias SessionSink = (String, [AgentSession]) -> Void

    private let monitors: [String: any AgentActivityMonitor]
    private let onSessions: SessionSink
    private var running = Set<String>()
    private var cancellables = Set<AnyCancellable>()

    init(monitors: [String: any AgentActivityMonitor],
         disconnected: Set<String>,
         onSessions: @escaping SessionSink) {
        self.monitors = monitors
        self.onSessions = onSessions

        for (id, monitor) in monitors {
            monitor.sessionsPublisher
                .sink { [weak self] in self?.onSessions(id, $0) }
                .store(in: &cancellables)
        }
        apply(disconnected: disconnected)
    }

    func apply(disconnected: Set<String>) {
        for (id, monitor) in monitors {
            if disconnected.contains(id) {
                if running.remove(id) != nil { monitor.stop() }
                onSessions(id, [])
            } else if running.insert(id).inserted {
                monitor.start()
            }
        }
    }
}
```

In `AppDelegate`, replace the unconditional `monitor.start()` loop with a retained `ProviderActivityController`. Its sink must call `fleet.setSessions(providerID:sessions:)` and `announceCompletions(sessions:)`. Subscribe `preferences.$disconnectedProviders` to both `store.disconnected` and `activityController.apply(disconnected:)`.

- [ ] **Step 4: Run lifecycle tests and the Safe test suite**

Run the focused command from Step 2, then:

```bash
make test-ci
```

Expected: the focused tests and all `CodenotchTests` pass.

- [ ] **Step 5: Commit the provider-lifecycle change**

```bash
git add Sources/Sessions/ProviderActivityController.swift Sources/App/AppDelegate.swift SafeTests/SecurityBoundaryTests.swift
git commit -m "fix: stop monitors for disabled providers"
```

---

### Task 2: Add the custom About window and working application commands

**Files:**
- Create: `Sources/About/AboutMetadata.swift`
- Create: `Sources/About/AboutView.swift`
- Create: `Sources/About/AboutWindowController.swift`
- Create: `Sources/App/AppMenuActions.swift`
- Create: `Sources/App/CodenotchCommands.swift`
- Modify: `Sources/App/CodenotchMain.swift:1-13`
- Modify: `Sources/App/AppDelegate.swift:8-100`
- Test: `SafeTests/SecurityBoundaryTests.swift`

**Interfaces:**
- Produces: `AboutMetadata.originalSourceURL`, `safeSourceURL`, `auditURL`, `licenseURL`, `copyright`, and `safeChanges`.
- Produces: `AppMenuActions.openAbout()` and `openSettings()`.
- Produces: `AboutWindowController.show()`.
- Consumes: the existing `SettingsWindowController.show()`.

- [ ] **Step 1: Write failing attribution and menu-routing tests**

Add:

```swift
final class AboutMetadataTests: XCTestCase {
    func testCreditsAndLinksIdentifyUpstreamAndSafeFork() {
        XCTAssertEqual(AboutMetadata.originalAuthor, "Vinz")
        XCTAssertEqual(AboutMetadata.copyright, "Copyright (c) 2026 Vinz")
        XCTAssertEqual(AboutMetadata.originalSourceURL.absoluteString,
                       "https://github.com/vinzdg/codenotch")
        XCTAssertEqual(AboutMetadata.safeSourceURL.absoluteString,
                       "https://github.com/x950827/codenotch-safe")
        XCTAssertEqual(AboutMetadata.auditURL.absoluteString,
                       "https://github.com/x950827/codenotch-safe/blob/main/SECURITY-AUDIT.md")
        XCTAssertEqual(AboutMetadata.licenseURL.absoluteString,
                       "https://github.com/vinzdg/codenotch/blob/main/LICENSE")
    }

    func testSafeChangesNameEveryAuditedBoundary() {
        let text = AboutMetadata.safeChanges.joined(separator: " ")
        for required in ["Claude", "Cursor", "Codex", "Keychain",
                         "bearer", "web view", "updater", "CI"] {
            XCTAssertTrue(text.localizedCaseInsensitiveContains(required), required)
        }
    }
}

@MainActor
final class AppMenuActionsTests: XCTestCase {
    func testCommandsRouteToTheirOwnWindows() {
        var opened: [String] = []
        let actions = AppMenuActions(
            showAbout: { opened.append("about") },
            showSettings: { opened.append("settings") }
        )

        actions.openAbout()
        actions.openSettings()

        XCTAssertEqual(opened, ["about", "settings"])
    }
}
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run `make test-ci`.

Expected: compilation fails because `AboutMetadata` and `AppMenuActions` do not exist.

- [ ] **Step 3: Implement metadata, window, and commands**

Implement `AboutMetadata` with the exact tested constants and this lead sentence:

```swift
static let attribution = "Codenotch Safe is based on Codenotch by Vinz."
```

Implement `AppMenuActions` as a small `@MainActor` value that retains two closures and exposes `openAbout()` and `openSettings()`. Implement `CodenotchCommands: Commands` with:

```swift
CommandGroup(replacing: .appInfo) {
    Button("About Codenotch Safe", action: actions.openAbout)
}
CommandGroup(replacing: .appSettings) {
    Button("Settings…", action: actions.openSettings)
        .keyboardShortcut(",", modifiers: .command)
}
```

Build `AboutView` from `AboutMetadata`, `Bundle.main` version/build values, `Link` controls, and a `View MIT License` button. `AboutWindowController` owns a fixed-size `NSWindow`, uses `NSHostingView`, restores the selected `AppPresence` policy when it closes, and opens `Bundle.main.url(forResource: "LICENSE", withExtension: "txt")` through `NSWorkspace`.

Give `AppDelegate` retained `about` and `menuActions` properties. Construct `AboutWindowController` at launch and wire the menu closures to the About and Settings controllers. Attach `CodenotchCommands` to the `Settings { EmptyView() }` scene in `CodenotchMain` so the empty default Settings window is never invoked.

- [ ] **Step 4: Run tests and manually open both commands from a debug build**

Run:

```bash
make test-ci
make safe-verify
open 'build/safe/Codenotch Safe.app'
```

Launch the verified app, then confirm **About Codenotch Safe** and **Settings…** each open their intended window and Command-comma opens Settings.

- [ ] **Step 5: Commit the About and menu change**

```bash
git add Sources/About Sources/App/AppMenuActions.swift Sources/App/CodenotchCommands.swift Sources/App/CodenotchMain.swift Sources/App/AppDelegate.swift SafeTests/SecurityBoundaryTests.swift
git commit -m "feat: add safe about and app commands"
```

---

### Task 3: Bundle the MIT license and correct Safe account copy

**Files:**
- Create: `Sources/Resources/LICENSE.txt`
- Modify: `Sources/About/AboutMetadata.swift`
- Modify: `Sources/Settings/SettingsView.swift:300-370,930-975`
- Modify: `Sources/Settings/SettingsWindowController.swift:10-45,130-150`
- Modify: `Sources/App/AppDelegate.swift:75-92`
- Modify: `Sources/Info.plist`
- Modify: `project.yml`
- Test: `SafeTests/SecurityBoundaryTests.swift`

**Interfaces:**
- Produces: `AboutMetadata.accountAccessExplanation` used by Settings.
- Produces: `Contents/Resources/LICENSE.txt` in both Xcode and direct builds.

- [ ] **Step 1: Write failing disclosure and license tests**

Add:

```swift
final class SafeDisclosureTests: XCTestCase {
    func testAccountCopyMatchesSafeCredentialBoundary() {
        let text = AboutMetadata.accountAccessExplanation
        XCTAssertTrue(text.contains("disabled provider is not queried"))
        XCTAssertTrue(text.contains("Cursor"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("Always Allow"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("Keychain password"))
    }

    func testBundledLicenseMatchesRepositoryLicense() throws {
        let bundled = try XCTUnwrap(Bundle(for: Self.self)
            .url(forResource: "LICENSE", withExtension: "txt"))
        let text = try String(contentsOf: bundled, encoding: .utf8)
        XCTAssertTrue(text.contains("MIT License"))
        XCTAssertTrue(text.contains("Copyright (c) 2026 Vinz"))
        XCTAssertTrue(text.contains("copies or substantial portions"))
    }

    @MainActor
    func testSafe12PreferenceKeysRemainReadable() {
        let suite = "Safe12Preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["cursor"], forKey: "hiddenProviders")
        defaults.set(NotchScreenScope.allDisplays.rawValue, forKey: "notchScope")
        defaults.set(AppPresence.menuBar.rawValue, forKey: "appPresence")

        let preferences = Preferences(defaults: defaults)

        XCTAssertEqual(preferences.disconnectedProviders, Set(["cursor"]))
        XCTAssertEqual(preferences.notchScope, .allDisplays)
        XCTAssertEqual(preferences.appPresence, .menuBar)
    }
}
```

- [ ] **Step 2: Run the tests and verify the missing resource/copy failures**

Run `make test-ci`.

Expected: compilation fails for `accountAccessExplanation` or the test cannot find `LICENSE.txt`.

- [ ] **Step 3: Add the exact license and Safe disclosure**

Copy the repository `LICENSE` byte-for-byte to `Sources/Resources/LICENSE.txt`. Its location under `Sources` places it in the application resource phase; add the same path explicitly to the `CodenotchTests` resource phase in `project.yml` so `Bundle(for:)` can verify it independently.

Set `AboutMetadata.accountAccessExplanation` to:

```swift
"Codenotch Safe reads limits from local integrations already used by Claude and Codex. Cursor may contact its usage endpoint when enabled. A disabled provider is not queried and its activity monitor is stopped."
```

Use this constant below the provider switches. Remove the obsolete **Allow access…** button, its `retry` closure, and the associated plumbing from `SettingsView`, `SettingsWindowController`, and `AppDelegate`. Remove every instruction to choose **Always Allow** from the Safe settings source. Add this exact `Info.plist` value:

```xml
<key>NSHumanReadableCopyright</key>
<string>Copyright (c) 2026 Vinz. Codenotch Safe modifications distributed under the MIT License.</string>
```

- [ ] **Step 4: Verify copy, resources, and prohibited text**

Run:

```bash
make test-ci
rg -n "Always Allow|Keychain password" Sources/App Sources/About Sources/Settings Sources/Resources
```

Expected: tests pass and `rg` returns no match.

- [ ] **Step 5: Commit the license and copy correction**

```bash
git add Sources/Resources/LICENSE.txt Sources/About/AboutMetadata.swift Sources/Settings/SettingsView.swift Sources/Settings/SettingsWindowController.swift Sources/App/AppDelegate.swift Sources/Info.plist project.yml SafeTests/SecurityBoundaryTests.swift
git commit -m "docs: disclose safe fork attribution and access"
```

---

### Task 4: Produce and verify a universal Safe application

**Files:**
- Create: `Scripts/safe-release-metadata.sh`
- Create: `Scripts/test-safe-release-metadata.sh`
- Modify: `Scripts/build-safe-local.sh`
- Modify: `Scripts/verify-safe-local.sh`
- Modify: `Makefile`
- Modify: `project.yml`

**Interfaces:**
- Produces: `safe_version`, `safe_build`, `safe_tag`, and `safe_app_name` after sourcing `Scripts/safe-release-metadata.sh`.
- Produces: `build/safe/Codenotch Safe.app` with universal main and helper executables.
- Consumes: `CODENOTCH_SIGNING_IDENTITY`, preserving `-` for CI and the stable local certificate for local builds.

- [ ] **Step 1: Add a failing release-metadata policy test**

Create `Scripts/test-safe-release-metadata.sh` that sources the metadata helper and asserts:

```zsh
[[ "$safe_version" == "1.6.0-safe.13" ]]
[[ "$safe_build" == "13" ]]
[[ "$safe_tag" == "v1.6.0-safe.13" ]]
[[ "$safe_app_name" == "Codenotch Safe" ]]
```

It must also call the helper with `v1.6.0-safe.12` and assert that tag validation fails.

- [ ] **Step 2: Run the metadata test and verify it fails**

Run `zsh Scripts/test-safe-release-metadata.sh`.

Expected: failure because `Scripts/safe-release-metadata.sh` does not exist.

- [ ] **Step 3: Implement one-source metadata and two-architecture compilation**

Set `MARKETING_VERSION: "1.6.0-safe.13"`, `CURRENT_PROJECT_VERSION: "13"`, and the macOS deployment target to `15.0` in `project.yml`. Use `15.0` for both direct-build architecture slices and `LSMinimumSystemVersion`. Implement the metadata helper by reading the two quoted release values with `awk`, defining the exact app name, and exposing a `safe_validate_tag` function.

The helper uses the repository `project.yml` as the only version/build source:

```zsh
safe_version=$(/usr/bin/awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' "$repo_root/project.yml")
safe_build=$(/usr/bin/awk -F'"' '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$repo_root/project.yml")
safe_tag="v${safe_version}"
safe_app_name="Codenotch Safe"

safe_validate_tag() {
    [[ ${1:-} == "$safe_tag" ]] || {
        print -u2 "release tag ${1:-<missing>} does not match $safe_tag"
        return 1
    }
}
```

Update `build-safe-local.sh` to:

1. source the metadata helper;
2. create `build/safe/Codenotch Safe.app`;
3. compile every source twice with `-target arm64-apple-macosx${deployment_target}` and `-target x86_64-apple-macosx${deployment_target}`;
4. keep separate module caches per architecture;
5. combine the two main binaries and the two helper binaries with `/usr/bin/lipo -create`;
6. copy `LICENSE.txt`, the menu-bar SVG, and an `AppIcon.icns` generated from the existing iconset;
7. write version, build, bundle ID, copyright, icon, and minimum-system keys from canonical metadata;
8. sign the fully assembled bundle once.

Use separate output and module-cache directories, then combine only after every compile succeeds:

```zsh
architectures=(arm64 x86_64)
for architecture in "${architectures[@]}"; do
    arch_root="$build_root/$architecture"
    /bin/mkdir -p "$arch_root/main-module-cache" "$arch_root/helper-module-cache"
    /usr/bin/xcrun swiftc -O -parse-as-library -module-name Codenotch \
        -sdk "$sdk_path" -target "${architecture}-apple-macosx${deployment_target}" \
        -module-cache-path "$arch_root/main-module-cache" \
        "${source_files[@]}" -lsqlite3 -o "$arch_root/Codenotch"
    /usr/bin/xcrun swiftc -O -parse-as-library -module-name CodenotchClaudeStatusLine \
        -sdk "$sdk_path" -target "${architecture}-apple-macosx${deployment_target}" \
        -module-cache-path "$arch_root/helper-module-cache" \
        "${helper_sources[@]}" -o "$arch_root/CodenotchClaudeStatusLine"
done
/usr/bin/lipo -create "$build_root/arm64/Codenotch" "$build_root/x86_64/Codenotch" \
    -output "$executable"
/usr/bin/lipo -create "$build_root/arm64/CodenotchClaudeStatusLine" \
    "$build_root/x86_64/CodenotchClaudeStatusLine" -output "$status_line_helper"
```

Update the Makefile and every verification path to quote `build/safe/Codenotch Safe.app`.

- [ ] **Step 4: Extend the verifier before accepting the build**

Require both executables to report exactly these slices:

```zsh
[[ "$(/usr/bin/lipo -archs "$verified_executable")" == "x86_64 arm64" \
   || "$(/usr/bin/lipo -archs "$verified_executable")" == "arm64 x86_64" ]]
```

Repeat for the helper. Read expected version/build from `safe-release-metadata.sh`, check the app display name and copyright, compare bundled `LICENSE.txt` with the repository `LICENSE`, and retain every existing symbol, import, entitlement, signing, destination, and Claude cache check.

- [ ] **Step 5: Run the complete universal build gate**

Run:

```bash
zsh Scripts/test-safe-release-metadata.sh
CODENOTCH_SIGNING_IDENTITY=- make safe-verify
lipo -archs 'build/safe/Codenotch Safe.app/Contents/MacOS/Codenotch'
lipo -archs 'build/safe/Codenotch Safe.app/Contents/MacOS/CodenotchClaudeStatusLine'
```

Expected: all checks pass and both `lipo` commands print `x86_64 arm64` or `arm64 x86_64`.

- [ ] **Step 6: Commit the universal build**

```bash
git add Scripts Makefile project.yml
git commit -m "build: produce universal safe app"
```

---

### Task 5: Package and verify the release DMG

**Files:**
- Create: `Distribution/FIRST-LAUNCH.txt`
- Create: `Distribution/RELEASE-NOTES.md`
- Create: `Scripts/package-safe-release.sh`
- Create: `Scripts/verify-safe-release.sh`
- Create: `Scripts/test-safe-packaging-policy.sh`
- Modify: `Makefile`

**Interfaces:**
- Produces: `build/release/Codenotch-Safe-1.6.0-safe.13-universal.dmg`.
- Produces: `build/release/SHA256SUMS.txt` with the DMG hash and basename.
- Consumes: the already verified `build/safe/Codenotch Safe.app`.

- [ ] **Step 1: Write the failing packaging policy test**

Create a test that requires the package target's output filenames to exist. Mount the DMG at a temporary mount point and assert these entries exist:

```text
Codenotch Safe.app
Applications
LICENSE.txt
FIRST-LAUNCH.txt
```

The test must also compare the DMG's `LICENSE.txt` with the repository license, verify the application signature, verify both executable architectures, and validate `SHA256SUMS.txt` with `shasum -a 256 -c`.

- [ ] **Step 2: Run the packaging test and verify it fails**

Run `zsh Scripts/test-safe-packaging-policy.sh`.

Expected: failure because the package target and script do not exist.

- [ ] **Step 3: Implement deterministic staging and packaging**

Write `FIRST-LAUNCH.txt` with these steps:

```text
Codenotch Safe is ad-hoc signed and is not notarized by Apple.
If macOS blocks the first launch, open System Settings > Privacy & Security,
find the Codenotch Safe message, and choose Open Anyway. Confirm Open once.
Do not disable Gatekeeper globally.
Source: https://github.com/x950827/codenotch-safe
Audit: https://github.com/x950827/codenotch-safe/blob/main/SECURITY-AUDIT.md
```

Write release notes with the same signing disclosure, supported architectures, installation choices, upstream attribution, source, audit, and MIT links.

Implement `package-safe-release.sh` to recreate its local `build/release` directory, stage the verified app, an `/Applications` symlink, root `LICENSE.txt`, and `FIRST-LAUNCH.txt`; create a compressed read-only DMG with `hdiutil create -format UDZO`; and write the SHA-256 file. Remote release immutability is enforced later by `gh release create` without `--clobber`.

The packaging core is:

```zsh
/bin/rm -rf "$release_dir"
/bin/mkdir -p "$stage"
/usr/bin/ditto --norsrc "$safe_app" "$stage/Codenotch Safe.app"
/bin/ln -s /Applications "$stage/Applications"
/bin/cp "$repo_root/LICENSE" "$stage/LICENSE.txt"
/bin/cp "$repo_root/Distribution/FIRST-LAUNCH.txt" "$stage/FIRST-LAUNCH.txt"
/usr/bin/hdiutil create -volname "Codenotch Safe" -srcfolder "$stage" \
    -ov -format UDZO "$dmg"
/bin/rm -rf "$stage"
(
    cd "$release_dir"
    /usr/bin/shasum -a 256 "${dmg:t}" > SHA256SUMS.txt
)
```

Implement `verify-safe-release.sh` to mount read-only, validate all four entries, compare licenses, run strict `codesign`, inspect both architectures, validate the checksum, and detach in a trap.

Add `safe-package: safe-verify` and `safe-release-verify: safe-package` targets.

- [ ] **Step 4: Build once and run the independent package policy checks**

Run:

```bash
make clean
CODENOTCH_SIGNING_IDENTITY=- make safe-release-verify
zsh Scripts/test-safe-packaging-policy.sh
```

Expected: the first command produces and verifies the DMG; the policy test passes against it.

- [ ] **Step 5: Commit the packaging pipeline**

```bash
git add Distribution Scripts/package-safe-release.sh Scripts/verify-safe-release.sh Scripts/test-safe-packaging-policy.sh Makefile
git commit -m "build: package safe release dmg"
```

---

### Task 6: Render a checksum-pinned Homebrew Cask and document installation

**Files:**
- Create: `Distribution/Casks/codenotch-safe.rb.in`
- Create: `Scripts/render-homebrew-cask.sh`
- Modify: `Scripts/test-safe-packaging-policy.sh`
- Modify: `Makefile`
- Modify: `README.md`

**Interfaces:**
- Produces: `build/homebrew-tap/Casks/codenotch-safe.rb`.
- Consumes: canonical version/tag metadata and the verified DMG SHA-256.

- [ ] **Step 1: Extend the policy test with failing cask assertions**

After packaging, run the renderer and assert:

```zsh
grep -Fq 'version "1.6.0-safe.13"' "$cask"
grep -Fq 'app "Codenotch Safe.app"' "$cask"
grep -Fq 'https://github.com/x950827/codenotch-safe/releases/download/v#{version}' "$cask"
! grep -Eq 'sha256 :no_check|quarantine|postflight|installer ' "$cask"
ruby -c "$cask"
```

Also extract the cask SHA and compare it with `SHA256SUMS.txt`.

- [ ] **Step 2: Run the policy test and verify the renderer is missing**

Run `zsh Scripts/test-safe-packaging-policy.sh`.

Expected: failure because the cask template or renderer does not exist.

- [ ] **Step 3: Implement the cask template and renderer**

The template must render this structure with an exact checksum:

```ruby
cask "codenotch-safe" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/x950827/codenotch-safe/releases/download/v#{version}/Codenotch-Safe-#{version}-universal.dmg"
  name "Codenotch Safe"
  desc "Audited Claude, Cursor, and Codex usage monitor"
  homepage "https://github.com/x950827/codenotch-safe"

  depends_on macos: ">= :sequoia"

  app "Codenotch Safe.app"

  caveats <<~EOS
    This build is ad-hoc signed and is not notarized by Apple.
    If macOS blocks its first launch, use System Settings > Privacy & Security > Open Anyway.
    Do not disable Gatekeeper globally.
  EOS
end
```

The renderer reads the verified checksum, replaces both placeholders, and refuses empty or malformed values. Add a `safe-homebrew: safe-release-verify` Make target.

Render through escaped replacements rather than evaluating the template:

```zsh
sha256=$(/usr/bin/awk 'NF == 2 { print $1; exit }' "$checksums")
[[ ${#sha256} -eq 64 && "$sha256" != *[^0-9a-fA-F]* ]] || {
    print -u2 "invalid DMG checksum"
    exit 1
}
/usr/bin/sed -e "s/__VERSION__/$safe_version/g" -e "s/__SHA256__/$sha256/g" \
    "$template" > "$cask"
```

Update README with direct-download instructions, the exact Brew command, the first-launch UI steps, provider switches, upstream author, Safe changes, audit, and MIT links.

- [ ] **Step 4: Validate the local tap output**

Run:

```bash
make safe-homebrew
ruby -c build/homebrew-tap/Casks/codenotch-safe.rb
brew style --cask build/homebrew-tap/Casks/codenotch-safe.rb
```

Expected: renderer and Ruby syntax pass. `brew style` reports no offenses.

- [ ] **Step 5: Commit Homebrew packaging and user documentation**

```bash
git add Distribution/Casks Scripts/render-homebrew-cask.sh Scripts/test-safe-packaging-policy.sh Makefile README.md
git commit -m "feat: add homebrew cask packaging"
```

---

### Task 7: Add guarded CI and GitHub Release workflows

**Files:**
- Create: `.github/workflows/release.yml`
- Create: `Scripts/test-safe-release-workflow.sh`
- Modify: `.github/workflows/ci.yml`
- Modify: `Makefile`
- Modify: `SECURITY-AUDIT.md`

**Interfaces:**
- Pull requests produce an unpublished DMG artifact and checksum after all safety checks.
- An exact `v1.6.0-safe.13` tag produces one GitHub Release with the same DMG and checksum.
- The release workflow uses only `GITHUB_TOKEN` with `contents: write`; it consumes no Apple or provider credential.

- [ ] **Step 1: Write a failing release-workflow policy test**

Create `Scripts/test-safe-release-workflow.sh` to assert:

```zsh
grep -Fq 'tags: ["v*-safe.*"]' .github/workflows/release.yml
grep -Fq 'contents: write' .github/workflows/release.yml
grep -Fq 'gh release create' .github/workflows/release.yml
grep -Fq 'safe_validate_tag "$GITHUB_REF_NAME"' .github/workflows/release.yml
! grep -Eq 'APPLE_|NOTARY|SIGNING|--clobber|xattr|spctl --master-disable' .github/workflows/release.yml
```

Also assert every `uses:` reference in both workflow files is pinned to a full 40-character commit SHA.

- [ ] **Step 2: Run the policy test and verify the workflow is missing**

Run `zsh Scripts/test-safe-release-workflow.sh`.

Expected: failure because `.github/workflows/release.yml` does not exist.

- [ ] **Step 3: Implement CI packaging and tag publication**

Change Safe CI to run:

```bash
CODENOTCH_SIGNING_IDENTITY=- make safe-homebrew
```

Upload the DMG, `SHA256SUMS.txt`, and rendered cask as an unpublished workflow artifact.

Create the tag workflow with:

1. full-history checkout at the tag;
2. XcodeGen installation;
3. `make test-ci`;
4. `CODENOTCH_SIGNING_IDENTITY=- make safe-homebrew`;
5. tag validation through `safe_validate_tag`;
6. `gh release create "$GITHUB_REF_NAME" "$dmg" "$checksums" --verify-tag --title "Codenotch Safe $safe_version" --notes-file Distribution/RELEASE-NOTES.md`.

Use this job shape so tag validation occurs before upload and variables are recomputed in the step that consumes them:

```yaml
name: Safe Release

on:
  push:
    tags: ["v*-safe.*"]

permissions:
  contents: write

jobs:
  release:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262
        with:
          fetch-depth: 0
      - run: brew install xcodegen
      - run: make test-ci
      - name: Build distribution
        env:
          CODENOTCH_SIGNING_IDENTITY: "-"
        run: make safe-homebrew
      - name: Validate and publish tag
        env:
          GH_TOKEN: ${{ github.token }}
        shell: zsh {0}
        run: |
          source Scripts/safe-release-metadata.sh
          safe_validate_tag "$GITHUB_REF_NAME"
          dmg="build/release/Codenotch-Safe-${safe_version}-universal.dmg"
          checksums="build/release/SHA256SUMS.txt"
          gh release create "$GITHUB_REF_NAME" "$dmg" "$checksums" \
            --verify-tag \
            --title "Codenotch Safe $safe_version" \
            --notes-file Distribution/RELEASE-NOTES.md
```

Do not add `--clobber`; an existing release or asset must make the job fail.

- [ ] **Step 4: Run workflow, tests, build, and packaging policy locally**

Run:

```bash
zsh Scripts/test-safe-release-workflow.sh
make test-ci
CODENOTCH_SIGNING_IDENTITY=- make safe-homebrew
```

Expected: every command passes.

Update `SECURITY-AUDIT.md` with the Safe.13 source/runtime changes and the exact local commands that passed. Label GitHub run evidence and clean-account first-launch evidence as pending until those actions actually occur.

- [ ] **Step 5: Commit workflow and audit documentation**

```bash
git add .github/workflows Scripts/test-safe-release-workflow.sh Makefile SECURITY-AUDIT.md
git commit -m "ci: prepare safe team release"
```

---

### Task 8: Final local verification and publication packet

**Files:**
- Modify only if verification finds a defect in files already listed above.
- Produce: `build/release/Codenotch-Safe-1.6.0-safe.13-universal.dmg`
- Produce: `build/release/SHA256SUMS.txt`
- Produce: `build/homebrew-tap/Casks/codenotch-safe.rb`

**Interfaces:**
- Produces a reviewable commit range, artifact paths, hashes, test evidence, and exact proposed remote actions.

- [ ] **Step 1: Run the final clean verification**

Run:

```bash
make clean
make test-ci
CODENOTCH_SIGNING_IDENTITY=- make safe-homebrew
git diff --check
git status --short
```

Expected: tests, boundary verification, DMG verification, cask rendering, and diff check pass; only known generated directories remain untracked.

- [ ] **Step 2: Inspect the finished bundle and artifacts**

Run:

```bash
codesign --verify --deep --strict --verbose=2 'build/safe/Codenotch Safe.app'
codesign -dvvv 'build/safe/Codenotch Safe.app'
lipo -archs 'build/safe/Codenotch Safe.app/Contents/MacOS/Codenotch'
lipo -archs 'build/safe/Codenotch Safe.app/Contents/MacOS/CodenotchClaudeStatusLine'
/bin/zsh -c 'cd build/release && /usr/bin/shasum -a 256 -c SHA256SUMS.txt'
ruby -c build/homebrew-tap/Casks/codenotch-safe.rb
```

Expected: strict signature verification passes, signature details say ad-hoc, both binaries are universal, checksum validates, and cask syntax is valid.

- [ ] **Step 3: Review the complete branch**

Inspect every commit after `f642423` and compare the final diff with the approved spec. Run a code review focused on credential boundaries, release immutability, disabled-provider behavior, and license compliance. Fix any finding with its own test and commit, then repeat only the affected verification plus the final gate.

- [ ] **Step 4: Present the publication packet and request explicit authorization**

Report:

- named repository `x950827/codenotch-safe`;
- branch `audit/safe-local` and the exact new commit range;
- DMG filename and SHA-256;
- rendered preview cask path and content; the published cask will use the tag workflow's checksum for its canonical DMG;
- passed checks and remaining manual Gatekeeper check;
- proposed remote operations in order: push the named branch, update/merge PR #1, push tag `v1.6.0-safe.13`, let the tag workflow create the GitHub Release, create `x950827/homebrew-tap`, and push the exact cask commit only after its release URL resolves.

Do not perform any of those remote operations until the user explicitly authorizes them.

- [ ] **Step 5: After publication authorization, verify remote results**

After the authorized push/tag/repository actions, wait for both GitHub workflows, verify their exact commit and conclusion, download neither credentials nor account data, and run Homebrew's online audit against the published URL:

```bash
brew audit --cask --new --online x950827/tap/codenotch-safe
```

Download the published DMG and checksum to a temporary directory, run the release verifier against that copy, and confirm that the public cask pins the checksum published beside the DMG. The CI-built DMG may have a different hash from a local build because filesystem and signature timestamps are inputs; the release checksum and cask are the canonical pair. Record the run links and release URL in `SECURITY-AUDIT.md` in a follow-up documentation commit.

Before announcing the build to the team, use a clean macOS account or disposable macOS machine to install once from the DMG and once through the cask. Confirm both paths install the same hash, show the documented one-time Gatekeeper flow, preserve Safe.12 preferences when replacing that version, and launch normally afterward. Record that evidence without inspecting provider credentials.
