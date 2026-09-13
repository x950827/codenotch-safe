#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
source="$script_dir/../Sources/Safe/SafeClaudeOAuthUsage.swift"

no_ui_count=$(/usr/bin/grep -c \
    '^[[:space:]]*kSecUseAuthenticationContext: nonInteractiveContext(),' \
    "$source" || true)

if [[ "$no_ui_count" != "2" ]]; then
    print -u2 \
        "expected two non-interactive Claude Keychain queries, found $no_ui_count"
    exit 1
fi

print "safe Claude Keychain policy tests passed"
