# Stable Local Code Signing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make local Codenotch Safe rebuilds use the valid `Codenotch Local Signing` certificate while keeping CI on an explicit ad-hoc signing mode.

**Architecture:** Put deterministic identity parsing in a small zsh command with fixture tests. The build script resolves a valid certificate fingerprint before compilation, records its selected mode, and signs the existing metadata-free staging bundle; the verifier proves that the resulting leaf certificate and designated requirement match that selection.

**Tech Stack:** zsh, macOS `security` and `codesign`, Make, GitHub Actions, Swift command-line build, Markdown audit evidence

---

## File map

- Create `Scripts/resolve-safe-signing-identity.sh`: parse valid identity output and return one exact fingerprint or explicit `-`.
- Create `Scripts/test-safe-signing-selection.sh`: fixture tests for exact name, fingerprint, ambiguity, absence, near-name, and ad-hoc cases.
- Modify `Scripts/build-safe-local.sh`: resolve the signer, advance safe.8, sign by fingerprint, and record the selection.
- Modify `Scripts/verify-safe-local.sh`: record signature metadata and verify certificate/ad-hoc mode plus the designated requirement.
- Modify `Makefile`: run signing-selection tests in `safe-verify`.
- Modify `.github/workflows/ci.yml`: request ad-hoc signing explicitly because CI has no private key.
- Modify `SECURITY-AUDIT.md`: record safe.8 local signing, installed hashes, designated requirement, and CI distinction.

### Task 1: Build and test deterministic identity resolution

**Files:**
- Create: `Scripts/test-safe-signing-selection.sh`
- Create: `Scripts/resolve-safe-signing-identity.sh`

- [x] **Step 1: Write the failing fixture test**

Create `Scripts/test-safe-signing-selection.sh` with executable mode and this structure:

```zsh
#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
resolver="$script_dir/resolve-safe-signing-identity.sh"
scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codenotch-signing-test.XXXXXX")
trap '/bin/rm -rf "$scratch"' EXIT

fingerprint_a=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
fingerprint_b=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
one_match=$'  1) '$fingerprint_a$' "Codenotch Local Signing"\n     1 valid identities found'
two_matches=$'  1) '$fingerprint_a$' "Codenotch Local Signing"\n  2) '$fingerprint_b$' "Codenotch Local Signing"\n     2 valid identities found'
near_match=$'  1) '$fingerprint_a$' "Codenotch Local Signing Backup"\n     1 valid identities found'

expect_success() {
    local expected=$1 selector=$2 fixture=$3
    local actual
    actual=$(print -r -- "$fixture" | "$resolver" "$selector")
    [[ "$actual" == "$expected" ]] || {
        print -u2 "expected $expected for $selector, got $actual"
        exit 1
    }
}

expect_failure() {
    local selector=$1 fixture=$2 expected_message=$3
    local error_file="$scratch/error"
    if print -r -- "$fixture" | "$resolver" "$selector" 2>"$error_file"; then
        print -u2 "resolver unexpectedly accepted $selector"
        exit 1
    fi
    /usr/bin/grep -Fq "$expected_message" "$error_file" || {
        print -u2 "resolver returned the wrong failure for $selector"
        exit 1
    }
}

expect_success "$fingerprint_a" "Codenotch Local Signing" "$one_match"
expect_success "$fingerprint_a" "$fingerprint_a" "$one_match"
expect_success "$fingerprint_a" "${fingerprint_a:l}" "$one_match"
expect_success "-" "-" ""
expect_failure "Codenotch Local Signing" "$two_matches" "multiple valid code-signing identities match"
expect_failure "Codenotch Local Signing" "$near_match" "no valid code-signing identity matches"
expect_failure "$fingerprint_b" "$one_match" "no valid code-signing identity matches"
expect_failure "Codenotch Local Signing" "" "no valid code-signing identity matches"

print "safe signing identity selection tests passed"
```

- [x] **Step 2: Run the test and verify it fails because the resolver is absent**

Run:

```sh
rtk Scripts/test-safe-signing-selection.sh
```

Expected: nonzero exit with `resolve-safe-signing-identity.sh: no such file or directory`.

- [x] **Step 3: Implement the minimal resolver**

Create executable `Scripts/resolve-safe-signing-identity.sh`:

```zsh
#!/bin/zsh
set -euo pipefail

selector=${1:-Codenotch Local Signing}
if [[ "$selector" == "-" ]]; then
    print -r -- "-"
    exit 0
fi

selector_is_fingerprint=false
if [[ ${#selector} -eq 40 && "$selector" != *[^[:xdigit:]]* ]]; then
    selector_is_fingerprint=true
fi

identity_pattern='^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"([^"]+)"[[:space:]]*$'
matches=()
while IFS= read -r line; do
    if [[ "$line" =~ $identity_pattern ]]; then
        fingerprint=${match[1]:u}
        identity_name=${match[2]}
        if [[ "$selector_is_fingerprint" == true ]]; then
            [[ "$fingerprint" == "${selector:u}" ]] && matches+=("$fingerprint")
        else
            [[ "$identity_name" == "$selector" ]] && matches+=("$fingerprint")
        fi
    fi
done

case ${#matches[@]} in
    1) print -r -- "${matches[1]}" ;;
    0)
        print -u2 "no valid code-signing identity matches: $selector"
        exit 1
        ;;
    *)
        print -u2 "multiple valid code-signing identities match: $selector"
        exit 1
        ;;
esac
```

- [x] **Step 4: Run the fixture tests and live read-only resolution**

Run:

```sh
rtk Scripts/test-safe-signing-selection.sh
rtk proxy /bin/zsh -c '/usr/bin/security find-identity -v -p codesigning | Scripts/resolve-safe-signing-identity.sh "Codenotch Local Signing"'
```

Expected: the fixture suite passes and the live command prints exactly `FBDC365911D5BECFEF46AB583120B3A56F282185`.

- [x] **Step 5: Commit the resolver and tests**

```sh
rtk git add Scripts/resolve-safe-signing-identity.sh Scripts/test-safe-signing-selection.sh
rtk git commit -m "test: define safe signing identity selection"
```

### Task 2: Integrate certificate signing and explicit CI ad-hoc mode

**Files:**
- Modify: `Scripts/build-safe-local.sh`
- Modify: `Makefile`
- Modify: `.github/workflows/ci.yml`

- [x] **Step 1: Run an invalid-identity build to capture the current missing behavior**

Run:

```sh
rtk proxy /usr/bin/env CODENOTCH_SIGNING_IDENTITY=DOES-NOT-EXIST Scripts/build-safe-local.sh
```

Expected before implementation: the build succeeds because the environment variable is ignored. This is the failing behavioral check.

- [x] **Step 2: Resolve the signing mode before compilation**

After the build-mode argument check in `Scripts/build-safe-local.sh`, add:

```zsh
requested_signing_identity=${CODENOTCH_SIGNING_IDENTITY:-Codenotch Local Signing}
if [[ "$requested_signing_identity" == "-" ]]; then
    signing_identity=$("$script_dir/resolve-safe-signing-identity.sh" "-" </dev/null)
    signing_mode=adhoc
else
    valid_identities=$(/usr/bin/security find-identity -v -p codesigning)
    signing_identity=$(print -r -- "$valid_identities" \
        | "$script_dir/resolve-safe-signing-identity.sh" "$requested_signing_identity")
    signing_mode=certificate
fi
```

Change the Info.plist values to:

```xml
<key>CFBundleShortVersionString</key><string>1.6.0-safe.8</string>
<key>CFBundleVersion</key><string>8</string>
```

Replace the fixed ad-hoc signing command and final status with:

```zsh
/usr/bin/codesign --force --deep --sign "$signing_identity" "$staged_bundle"
/bin/rm -rf "$bundle"
/usr/bin/ditto --norsrc "$staged_bundle" "$bundle"

evidence="$build_root/verification"
/bin/mkdir -p "$evidence"
print -r -- "$signing_mode" > "$evidence/signing-mode.txt"
print -r -- "$signing_identity" > "$evidence/signing-identity.txt"
print "built $bundle ($signing_mode signing)"
```

- [x] **Step 3: Add the fixture suite to the safe verification graph**

Add `safe-signing-test` to `.PHONY`, then add:

```make
safe-signing-test:
	Scripts/test-safe-signing-selection.sh

safe-build: safe-typecheck safe-signing-test
	Scripts/build-safe-local.sh
```

- [x] **Step 4: Make ad-hoc signing explicit in GitHub Actions**

Change the safe bundle step in `.github/workflows/ci.yml` to:

```yaml
      - name: Build and verify audited app
        env:
          CODENOTCH_SIGNING_IDENTITY: "-"
        run: make safe-verify
```

- [x] **Step 5: Verify failure and CI-mode success**

Run:

```sh
rtk proxy /usr/bin/env CODENOTCH_SIGNING_IDENTITY=DOES-NOT-EXIST Scripts/build-safe-local.sh
rtk proxy /usr/bin/env CODENOTCH_SIGNING_IDENTITY=- make safe-verify
```

Expected: the first command fails before compilation with `no valid code-signing identity matches`; the second builds safe.8 and passes the existing verifier with explicit ad-hoc signing.

- [x] **Step 6: Commit the build integration**

```sh
rtk git add Scripts/build-safe-local.sh Makefile .github/workflows/ci.yml
rtk git commit -m "build: select stable local signing identity"
```

### Task 3: Verify signing identity and designated requirement

**Files:**
- Modify: `Scripts/verify-safe-local.sh`

- [x] **Step 1: Demonstrate that the old verifier does not enforce the recorded mode**

After an explicit ad-hoc build, temporarily put `certificate` and the valid local fingerprint into the two signing evidence files, then run:

```sh
rtk proxy /usr/bin/env CODENOTCH_SIGNING_IDENTITY=- Scripts/build-safe-local.sh
rtk proxy /bin/zsh -c 'print -r -- certificate > build/safe/verification/signing-mode.txt; print -r -- FBDC365911D5BECFEF46AB583120B3A56F282185 > build/safe/verification/signing-identity.txt'
rtk Scripts/verify-safe-local.sh
rtk proxy /usr/bin/env CODENOTCH_SIGNING_IDENTITY=- Scripts/build-safe-local.sh
```

Expected before implementation: success, proving the verifier ignores the recorded signer. Restore the two evidence files by rerunning the explicit ad-hoc build.

- [x] **Step 2: Capture and validate signing metadata**

Immediately after strict signature verification in `Scripts/verify-safe-local.sh`, add:

```zsh
signing_mode_file="$evidence/signing-mode.txt"
signing_identity_file="$evidence/signing-identity.txt"
[[ -f "$signing_mode_file" && -f "$signing_identity_file" ]] || {
    print -u2 "safe signing selection evidence is missing"
    exit 1
}

signing_mode=$(<"$signing_mode_file")
signing_identity=$(<"$signing_identity_file")
signature_details=$(/usr/bin/codesign -dvvv "$verified_bundle" 2>&1)
designated_requirement=$(/usr/bin/codesign -d -r- "$verified_bundle" 2>&1)
print -r -- "$signature_details" > "$evidence/signature-details.txt"
print -r -- "$designated_requirement" > "$evidence/designated-requirement.txt"

case "$signing_mode" in
    adhoc)
        [[ "$signing_identity" == "-" && "$signature_details" == *"Signature=adhoc"* ]] || {
            print -u2 "bundle does not match the recorded ad-hoc signing mode"
            exit 1
        }
        ;;
    certificate)
        [[ ${#signing_identity} -eq 40 && "$signing_identity" != *[^[:xdigit:]]* ]] || {
            print -u2 "recorded certificate fingerprint is invalid"
            exit 1
        }
        [[ "$signature_details" != *"Signature=adhoc"* ]] || {
            print -u2 "certificate signing was requested but the bundle is ad-hoc signed"
            exit 1
        }
        leaf_requirement="certificate leaf = H\"${signing_identity:u}\""
        /usr/bin/codesign --verify --strict "-R=$leaf_requirement" "$verified_bundle"
        [[ "$designated_requirement" != *"cdhash"* ]] || {
            print -u2 "certificate-signed bundle has a hash-only designated requirement"
            exit 1
        }
        ;;
    *)
        print -u2 "unknown safe signing mode: $signing_mode"
        exit 1
        ;;
esac
```

Also assert the new bundle versions after the existing bundle-ID check:

```zsh
short_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$verified_bundle/Contents/Info.plist")
bundle_version=$(/usr/bin/plutil -extract CFBundleVersion raw "$verified_bundle/Contents/Info.plist")
[[ "$short_version" == "1.6.0-safe.8" && "$bundle_version" == "8" ]] || {
    print -u2 "unexpected safe bundle version: $short_version ($bundle_version)"
    exit 1
}
```

- [x] **Step 3: Run both signing modes through the strengthened verifier**

Run:

```sh
rtk proxy /usr/bin/env CODENOTCH_SIGNING_IDENTITY=- make safe-verify
rtk make safe-verify
rtk codesign -d -r- --verbose=4 build/safe/Codenotch.app
rtk cat build/safe/verification/signature-details.txt
```

Expected: explicit ad-hoc and local certificate builds both pass; the final signature names `Codenotch Local Signing`, the recorded fingerprint is `FBDC365911D5BECFEF46AB583120B3A56F282185`, and the final designated requirement contains no `cdhash` term.

- [x] **Step 4: Run static checks and commit**

```sh
rtk git diff --check
rtk git status --short
rtk git add Scripts/verify-safe-local.sh
rtk git commit -m "verify: enforce safe signing evidence"
```

### Task 4: Install and validate safe.8

**Files:**
- Modify: `SECURITY-AUDIT.md`
- Runtime-only: `/Applications/Codenotch Safe.app`
- Runtime-only: `/Applications/Codenotch Safe.app.safe7-rollback`

- [x] **Step 1: Produce final local evidence**

Run the certificate build outside the sandbox so the private key is available:

```sh
rtk make safe-verify
rtk codesign --verify --deep --strict --verbose=2 build/safe/Codenotch.app
rtk codesign -d -r- --verbose=4 build/safe/Codenotch.app
rtk cat build/safe/verification/sha256.txt
rtk defaults export local.audited.codenotch /tmp/codenotch-safe-before.plist
```

Expected: all checks pass; the signature is certificate-backed, the requirement is stable, and two SHA-256 values are recorded.

- [x] **Step 2: Preserve safe.7 and install safe.8 atomically**

Verify the current installed bundle and confirm the rollback destination is absent. Quit the running app, move the installed safe.7 bundle to `/Applications/Codenotch Safe.app.safe7-rollback`, copy the verified safe.8 bundle into `/Applications/Codenotch Safe.app`, and restore the rollback if the copy or verification fails.

Use these commands inside the approved installation transaction:

```sh
rtk codesign --verify --deep --strict --verbose=2 "/Applications/Codenotch Safe.app"
rtk test ! -e "/Applications/Codenotch Safe.app.safe7-rollback"
rtk osascript -e 'tell application id "local.audited.codenotch" to quit'
rtk mv "/Applications/Codenotch Safe.app" "/Applications/Codenotch Safe.app.safe7-rollback"
rtk ditto --norsrc "build/safe/Codenotch.app" "/Applications/Codenotch Safe.app"
rtk codesign --verify --deep --strict --verbose=2 "/Applications/Codenotch Safe.app"
```

If either `ditto` or the final signature check fails, move the failed safe.8
bundle into a fresh `mktemp -d` directory and restore safe.7:

```sh
rtk proxy /bin/zsh -c 'failure_dir=$(/usr/bin/mktemp -d /tmp/codenotch-safe8-failed.XXXXXX); /bin/mv "/Applications/Codenotch Safe.app" "$failure_dir/Codenotch Safe.app"; /bin/mv "/Applications/Codenotch Safe.app.safe7-rollback" "/Applications/Codenotch Safe.app"'
```

- [x] **Step 3: Compare installed evidence and launch**

Run:

```sh
rtk shasum -a 256 "/Applications/Codenotch Safe.app/Contents/MacOS/Codenotch" "/Applications/Codenotch Safe.app/Contents/MacOS/CodenotchClaudeStatusLine"
rtk codesign -d -r- --verbose=4 "/Applications/Codenotch Safe.app"
rtk open "/Applications/Codenotch Safe.app"
```

Expected: installed hashes equal the verified build hashes and the installed designated requirement equals the build requirement. If macOS presents the Claude credential prompt, pause for the user to choose **Always Allow**.

- [x] **Step 4: Validate a fresh normalized refresh without exposing credentials**

Create `/tmp/inspect-codenotch-archive.py` with this bounded decoder:

```python
#!/usr/bin/python3
import json
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    archive = plistlib.load(source).get("lastGoodReadings", b"[]")

entries = json.loads(archive)
safe = []
for entry in entries:
    windows = []
    for window in entry.get("windows", []):
        windows.append({
            "id": window.get("id"),
            "usedFraction": window.get("usedFraction"),
            "remaining": window.get("remaining"),
            "used": window.get("used"),
            "resetsAt": window.get("resetsAt"),
        })
    safe.append({
        "id": entry.get("id"),
        "fetchedAt": entry.get("fetchedAt"),
        "windows": windows,
    })

print(json.dumps(sorted(safe, key=lambda item: item["id"] or ""), indent=2))
```

After launching, wait for the initial refresh and export the current domain:

```sh
rtk sleep 30
rtk defaults export local.audited.codenotch /tmp/codenotch-safe-after.plist
rtk python3 /tmp/inspect-codenotch-archive.py /tmp/codenotch-safe-before.plist
rtk python3 /tmp/inspect-codenotch-archive.py /tmp/codenotch-safe-after.plist
rtk pgrep -alf '/Applications/Codenotch Safe.app/Contents/MacOS/Codenotch|claude|codex'
```

The decoder reports only provider ID, normalized windows, reset timestamps,
and `fetchedAt`; it omits every other preference key.

Confirm that at least one enabled provider receives a newer `fetchedAt`, the app process remains the exact installed executable, and observed children remain limited to the audited `claude` and `codex` commands. Do not print Keychain data, token values, account identifiers, raw provider bodies, or unrelated process arguments.

- [x] **Step 5: Update the audit with observed values**

Replace the safe.7 version, commit, hashes, ad-hoc-only wording, installed verification, and runtime paragraph in `SECURITY-AUDIT.md` with the exact safe.8 evidence from Steps 1-4. State that the local artifact uses `Codenotch Local Signing`, CI intentionally uses ad-hoc signing, and Claude Code credential rotation can still cause a new prompt.

- [x] **Step 6: Verify documentation, update the code index, and commit**

```sh
rtk git diff --check
rtk rg -n "safe[.]7|ad-hoc signed|Bundle version" SECURITY-AUDIT.md Scripts .github/workflows Makefile
rtk ccc search --refresh stable local code signing identity designated requirement
rtk git add SECURITY-AUDIT.md
rtk git commit -m "docs: record safe.8 signed installation"
```

Expected: any remaining `safe.7` reference is historical rollback context, no statement calls the local safe.8 app ad-hoc signed, and the index refresh reports no errors.

### Task 5: Push and verify CI

**Files:**
- No new files

- [x] **Step 1: Run final local verification from a clean tracked tree**

```sh
rtk git status --short --branch
rtk make safe-signing-test
rtk Scripts/build-safe-local.sh --typecheck
rtk Scripts/verify-safe-local.sh
rtk git diff --check
```

Expected: only the pre-existing `.build/` and `.cocoindex_code/` paths are
untracked, the resolver and type-check pass, the already installed and audited
certificate build remains byte-identical, its verifier passes, and there is no
diff error. Do not re-sign after recording the installed hashes because the
CMS signing time would produce a different bundle hash.

- [x] **Step 2: Push the branch and wait for Safe CI**

```sh
rtk git push origin audit/safe-local
rtk gh run list --workflow "Safe CI" --branch audit/safe-local --limit 1 --json databaseId,url,status,conclusion,headSha
rtk proxy /bin/zsh -c 'run_id=$(gh run list --workflow "Safe CI" --branch audit/safe-local --limit 1 --json databaseId --jq ".[0].databaseId"); gh run watch "$run_id" --exit-status'
```

Expected: the new Safe CI run passes its XCTest suite, explicit ad-hoc safe build, strengthened verifier, and artifact upload.

- [x] **Step 3: Record final state**

Capture the final commit, CI URL, installed version, installed hashes, local signing authority, designated requirement, and rollback path. Report separately that the CI artifact is ad-hoc and the installed local artifact is certificate-signed.
