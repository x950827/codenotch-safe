#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
provider="$repo_root/Sources/Safe/ClaudeCLIOnlyProvider.swift"
oauth_source="$repo_root/Sources/Safe/SafeClaudeOAuthUsage.swift"

if [[ -e "$oauth_source" ]]; then
    print -u2 "safe Claude OAuth Keychain source must be absent"
    exit 1
fi

if /usr/bin/grep -n 'SafeClaudeOAuthUsage' "$provider"; then
    print -u2 "safe Claude provider must not use the OAuth Keychain fallback"
    exit 1
fi

if "$script_dir/safe-source-list.sh" \
    | /usr/bin/tr '\0' '\n' \
    | /usr/bin/grep -Fxq 'Sources/Safe/SafeClaudeOAuthUsage.swift'; then
    print -u2 "safe source list must exclude the OAuth Keychain fallback"
    exit 1
fi

print "safe Claude Keychain-free policy tests passed"
