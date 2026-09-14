#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
bundle="$repo_root/build/safe/Codenotch.app"
executable="$bundle/Contents/MacOS/Codenotch"
status_line_helper="$bundle/Contents/MacOS/CodenotchClaudeStatusLine"
evidence="$repo_root/build/safe/verification"

[[ -x "$executable" ]] || {
    print -u2 "safe executable is missing: $executable"
    exit 1
}
[[ -x "$status_line_helper" ]] || {
    print -u2 "Claude status-line helper is missing: $status_line_helper"
    exit 1
}

/bin/mkdir -p "$evidence"
# This repository lives under Documents, where File Provider can reattach
# package metadata between two consecutive commands. Reject every unrecognized
# attribute before copying the signed contents to a non-File-Provider staging
# directory. `--norsrc` omits the three recognized metadata attributes; the
# signature and every sealed file are copied unchanged and verified there.
while IFS= read -r attribute_line; do
    attribute=${attribute_line##*: }
    case "$attribute" in
        com.apple.FinderInfo|com.apple.fileprovider.fpfs#P|com.apple.provenance)
            ;;
        *)
            print -u2 "unexpected extended attribute in bundle: $attribute"
            exit 1
            ;;
    esac
done < <(/usr/bin/xattr -r "$bundle")

verification_staging=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codenotch-verify.XXXXXX")
trap '/bin/rm -rf "$verification_staging"' EXIT
verified_bundle="$verification_staging/Codenotch.app"
verified_executable="$verified_bundle/Contents/MacOS/Codenotch"
verified_status_line_helper="$verified_bundle/Contents/MacOS/CodenotchClaudeStatusLine"
/usr/bin/ditto --norsrc "$bundle" "$verified_bundle"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$verified_bundle"

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

entitlements=$(/usr/bin/codesign -d --entitlements :- "$verified_bundle" 2>/dev/null || true)
print -r -- "$entitlements" > "$evidence/entitlements.plist"
if [[ -n "$entitlements" ]] && [[ "$entitlements" != *"<dict/>"* ]] \
    && [[ "$entitlements" != *"<dict>"$'\n'"</dict>"* ]]; then
    print -u2 "unexpected code-signing entitlements"
    print -u2 -r -- "$entitlements"
    exit 1
fi

forbidden='hivinz|chatgpt[.]com/backend-api|api[.]github[.]com|cloudcode-pa[.]googleapis[.]com|cli-chat-proxy[.]grok[.]com|opencode[.]ai|perplexity[.]ai|posthog|sentry|appcast[.]xml'
for binary in "$verified_executable" "$verified_status_line_helper"; do
    if /usr/bin/strings "$binary" | /usr/bin/grep -Eiq "$forbidden"; then
        print -u2 "forbidden runtime destination or SDK string found in executable: $binary"
        /usr/bin/strings "$binary" | /usr/bin/grep -Ei "$forbidden"
        exit 1
    fi

    if /usr/bin/nm -u "$binary" | /usr/bin/grep -Eq 'SecItem(Add|Update|Delete)|WKWebView|SPU(Standard)?Updater'; then
        print -u2 "forbidden credential mutation, WebView, or updater symbol found: $binary"
        exit 1
    fi
done

if /usr/bin/nm -u "$verified_executable" | /usr/bin/grep -q 'SecItemCopyMatching'; then
    print -u2 "safe main executable must not read Keychain data"
    exit 1
fi
if /usr/bin/nm -u "$verified_status_line_helper" | /usr/bin/grep -q 'SecItemCopyMatching'; then
    print -u2 "status-line helper must not read Keychain data"
    exit 1
fi
if /usr/bin/strings "$verified_executable" \
    | /usr/bin/grep -Eiq 'api[.]anthropic[.]com|SecItemCopyMatching'; then
    print -u2 "safe main executable contains a Claude OAuth or Keychain boundary"
    exit 1
fi
if /usr/bin/strings "$verified_status_line_helper" \
    | /usr/bin/grep -Eiq 'anthropic[.]com|SecItemCopyMatching'; then
    print -u2 "status-line helper contains a network or Keychain boundary"
    exit 1
fi

while IFS= read -r -d '' source; do
    if /usr/bin/grep -nE '^import (Security|LocalAuthentication|WebKit|Sparkle)$' \
        "$repo_root/$source"; then
        print -u2 "forbidden import in compiled source: $source"
        exit 1
    fi
done < <("$script_dir/safe-source-list.sh")
if /usr/bin/grep -nE '^import (Security|WebKit|Sparkle)$' \
    "$repo_root/Tools/ClaudeStatusLineBridge/main.swift"; then
    print -u2 "forbidden import in Claude status-line bridge"
    exit 1
fi

if /usr/bin/grep -nE '[.]repeatForever[(]' \
    "$repo_root/Sources/Features/ProviderRing.swift"; then
    print -u2 "continuous provider-ring animation violates the idle CPU budget"
    exit 1
fi

if /usr/bin/grep -nF 'ClaudeProfile.discover' \
    "$repo_root/Sources/App/AppDelegate.swift"; then
    print -u2 "automatic Claude profile discovery violates the audited Claude boundary"
    exit 1
fi

/usr/bin/otool -L "$verified_executable" > "$evidence/linked-libraries.txt"
/usr/bin/otool -L "$verified_status_line_helper" > "$evidence/status-line-linked-libraries.txt"
executable_hash=$(/usr/bin/shasum -a 256 "$verified_executable" | /usr/bin/awk '{print $1}')
status_line_helper_hash=$(/usr/bin/shasum -a 256 "$verified_status_line_helper" | /usr/bin/awk '{print $1}')
print -r -- "$executable_hash  $executable" | /usr/bin/tee "$evidence/sha256.txt"
print -r -- "$status_line_helper_hash  $status_line_helper" | /usr/bin/tee -a "$evidence/sha256.txt"
/usr/bin/plutil -p "$verified_bundle/Contents/Info.plist" > "$evidence/info-plist.txt"

# The bridge must pass the original status-line bytes through while retaining
# only the normalized usage subset. This fixture includes fields that must
# never reach its cache.
bridge_fixture='{"session_id":"must-not-persist","transcript_path":"/private/must-not-persist","rate_limits":{"five_hour":{"used_percentage":11,"resets_at":4102444800,"secret":"must-not-persist"},"seven_day":{"used_percentage":18,"resets_at":4102444800}}}'
bridge_cache="$verification_staging/claude-statusline-usage.json"
bridge_output=$(print -rn -- "$bridge_fixture" | "$verified_status_line_helper" \
    --cache-file "$bridge_cache" -- /bin/cat)
[[ "$bridge_output" == "$bridge_fixture" ]] || {
    print -u2 "Claude status-line bridge did not preserve downstream input"
    exit 1
}
[[ $(/usr/bin/plutil -extract fiveHour.usedPercentage raw "$bridge_cache") == "11" ]]
[[ $(/usr/bin/plutil -extract sevenDay.usedPercentage raw "$bridge_cache") == "18" ]]
if /usr/bin/grep -Eq 'session_id|transcript|secret|must-not-persist' "$bridge_cache"; then
    print -u2 "Claude status-line bridge retained a forbidden input field"
    exit 1
fi
[[ $(/usr/bin/stat -f '%Lp' "$bridge_cache") == "600" ]] || {
    print -u2 "Claude status-line cache permissions are not 0600"
    exit 1
}

bundle_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw "$verified_bundle/Contents/Info.plist")
[[ "$bundle_id" == "local.audited.codenotch" ]] || {
    print -u2 "unexpected bundle id: $bundle_id"
    exit 1
}
short_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$verified_bundle/Contents/Info.plist")
bundle_version=$(/usr/bin/plutil -extract CFBundleVersion raw "$verified_bundle/Contents/Info.plist")
[[ "$short_version" == "1.6.0-safe.11" && "$bundle_version" == "11" ]] || {
    print -u2 "unexpected safe bundle version: $short_version ($bundle_version)"
    exit 1
}

print "allowed Codenotch network endpoint: https://cursor.com/api/usage-summary"
print "signature, entitlement, import, symbol, destination, Keychain-free Claude, and bundle checks passed"
