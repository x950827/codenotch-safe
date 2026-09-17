#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
release="$repo_root/.github/workflows/release.yml"
ci="$repo_root/.github/workflows/ci.yml"

[[ -f "$release" ]] || {
    print -u2 "safe release workflow is missing"
    exit 1
}

/usr/bin/grep -Fq 'tags: ["v*-safe.*"]' "$release"
/usr/bin/grep -Fq 'contents: write' "$release"
/usr/bin/grep -Fq 'gh release create' "$release"
/usr/bin/grep -Fq 'safe_validate_tag "$GITHUB_REF_NAME"' "$release"
if /usr/bin/grep -Eq 'APPLE_|NOTARY|SIGNING|--clobber|xattr|spctl --master-disable' \
    "$release"; then
    print -u2 "release workflow contains a forbidden publishing control"
    exit 1
fi

for workflow in "$ci" "$release"; do
    while IFS= read -r reference; do
        [[ "$reference" =~ '@[0-9a-f]{40}([[:space:]]|$)' ]] || {
            print -u2 "workflow action is not pinned to a full commit: $reference"
            exit 1
        }
    done < <(/usr/bin/grep -E '^[[:space:]]*uses:' "$workflow")
done

print "safe release workflow policy tests passed"
