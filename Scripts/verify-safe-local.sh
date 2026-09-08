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
/usr/bin/codesign --verify --deep --strict --verbose=2 "$bundle"

entitlements=$(/usr/bin/codesign -d --entitlements :- "$bundle" 2>/dev/null || true)
print -r -- "$entitlements" > "$evidence/entitlements.plist"
if [[ -n "$entitlements" ]] && [[ "$entitlements" != *"<dict/>"* ]] \
    && [[ "$entitlements" != *"<dict>"$'\n'"</dict>"* ]]; then
    print -u2 "unexpected code-signing entitlements"
    print -u2 -r -- "$entitlements"
    exit 1
fi

forbidden='hivinz|api[.]anthropic[.]com|chatgpt[.]com/backend-api|api[.]github[.]com|cloudcode-pa[.]googleapis[.]com|cli-chat-proxy[.]grok[.]com|opencode[.]ai|perplexity[.]ai|posthog|sentry|appcast[.]xml'
if /usr/bin/strings "$executable" | /usr/bin/grep -Eiq "$forbidden"; then
    print -u2 "forbidden runtime destination or SDK string found in executable"
    /usr/bin/strings "$executable" | /usr/bin/grep -Ei "$forbidden"
    exit 1
fi

if /usr/bin/nm -u "$executable" | /usr/bin/grep -Eq 'SecItemCopyMatching|WKWebView|SPU(Standard)?Updater'; then
    print -u2 "forbidden credential, WebView, or updater symbol found"
    exit 1
fi

while IFS= read -r -d '' source; do
    if /usr/bin/grep -nE '^import (Security|WebKit|Sparkle)$' "$repo_root/$source"; then
        print -u2 "forbidden import in compiled source: $source"
        exit 1
    fi
done < <("$script_dir/safe-source-list.sh")

/usr/bin/otool -L "$executable" > "$evidence/linked-libraries.txt"
/usr/bin/shasum -a 256 "$executable" | /usr/bin/tee "$evidence/sha256.txt"
/usr/bin/plutil -p "$bundle/Contents/Info.plist" > "$evidence/info-plist.txt"

bundle_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw "$bundle/Contents/Info.plist")
[[ "$bundle_id" == "local.audited.codenotch" ]] || {
    print -u2 "unexpected bundle id: $bundle_id"
    exit 1
}

print "allowed Codenotch network endpoint: https://cursor.com/api/usage-summary"
print "signature, entitlement, import, symbol, destination, and bundle checks passed"
