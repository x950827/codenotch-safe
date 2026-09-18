#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
source "$script_dir/safe-release-metadata.sh"

[[ "$safe_version" == "1.6.0-safe.14" ]]
[[ "$safe_build" == "14" ]]
[[ "$safe_tag" == "v1.6.0-safe.14" ]]
[[ "$safe_app_name" == "Codenotch Safe" ]]
safe_validate_tag "$safe_tag"

if safe_validate_tag "v1.6.0-safe.13" 2>/dev/null; then
    print -u2 "release metadata accepted a stale tag"
    exit 1
fi

print "safe release metadata tests passed"
