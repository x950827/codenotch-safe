#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
bundle="$repo_root/build/safe/Codenotch.app"
executable="$bundle/Contents/MacOS/Codenotch"
evidence="$repo_root/build/safe/verification"

[[ -x "$executable" ]] || {
    print -u2 "safe executable is missing: $executable"
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
/usr/bin/ditto --norsrc "$bundle" "$verified_bundle"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$verified_bundle"

entitlements=$(/usr/bin/codesign -d --entitlements :- "$verified_bundle" 2>/dev/null || true)
print -r -- "$entitlements" > "$evidence/entitlements.plist"
if [[ -n "$entitlements" ]] && [[ "$entitlements" != *"<dict/>"* ]] \
    && [[ "$entitlements" != *"<dict>"$'\n'"</dict>"* ]]; then
    print -u2 "unexpected code-signing entitlements"
    print -u2 -r -- "$entitlements"
    exit 1
fi

forbidden='hivinz|api[.]anthropic[.]com|chatgpt[.]com/backend-api|api[.]github[.]com|cloudcode-pa[.]googleapis[.]com|cli-chat-proxy[.]grok[.]com|opencode[.]ai|perplexity[.]ai|posthog|sentry|appcast[.]xml'
if /usr/bin/strings "$verified_executable" | /usr/bin/grep -Eiq "$forbidden"; then
    print -u2 "forbidden runtime destination or SDK string found in executable"
    /usr/bin/strings "$verified_executable" | /usr/bin/grep -Ei "$forbidden"
    exit 1
fi

if /usr/bin/nm -u "$verified_executable" | /usr/bin/grep -Eq 'SecItemCopyMatching|WKWebView|SPU(Standard)?Updater'; then
    print -u2 "forbidden credential, WebView, or updater symbol found"
    exit 1
fi

while IFS= read -r -d '' source; do
    if /usr/bin/grep -nE '^import (Security|WebKit|Sparkle)$' "$repo_root/$source"; then
        print -u2 "forbidden import in compiled source: $source"
        exit 1
    fi
done < <("$script_dir/safe-source-list.sh")

if /usr/bin/grep -nE '[.]repeatForever[(]' \
    "$repo_root/Sources/Features/ProviderRing.swift"; then
    print -u2 "continuous provider-ring animation violates the idle CPU budget"
    exit 1
fi

if /usr/bin/grep -nF 'ClaudeProfile.discover' \
    "$repo_root/Sources/App/AppDelegate.swift"; then
    print -u2 "automatic Claude profile discovery violates the audited CLI boundary"
    exit 1
fi

/usr/bin/otool -L "$verified_executable" > "$evidence/linked-libraries.txt"
executable_hash=$(/usr/bin/shasum -a 256 "$verified_executable" | /usr/bin/awk '{print $1}')
print -r -- "$executable_hash  $executable" | /usr/bin/tee "$evidence/sha256.txt"
/usr/bin/plutil -p "$verified_bundle/Contents/Info.plist" > "$evidence/info-plist.txt"

bundle_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw "$verified_bundle/Contents/Info.plist")
[[ "$bundle_id" == "local.audited.codenotch" ]] || {
    print -u2 "unexpected bundle id: $bundle_id"
    exit 1
}

print "allowed Codenotch network endpoint: https://cursor.com/api/usage-summary"
print "signature, entitlement, import, symbol, destination, and bundle checks passed"
