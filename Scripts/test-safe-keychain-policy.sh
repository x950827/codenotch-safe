#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
provider="$repo_root/Sources/Safe/ClaudeCLIOnlyProvider.swift"
cli="$repo_root/Sources/Providers/ClaudeUsageCLI.swift"
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

if /usr/bin/grep -n 'environment\["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"\]' "$cli"; then
    print -u2 "safe Claude CLI must allow its built-in /usage network request"
    exit 1
fi

for control in DISABLE_AUTOUPDATER DISABLE_TELEMETRY DISABLE_ERROR_REPORTING DISABLE_FEEDBACK_COMMAND; do
    if ! /usr/bin/grep -Fq "environment[\"$control\"] = \"1\"" "$cli"; then
        print -u2 "safe Claude CLI is missing the $control guard"
        exit 1
    fi
done

print "safe Claude Keychain-free policy tests passed"
