#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
source "$script_dir/safe-release-metadata.sh"

safe_app="$repo_root/build/safe/$safe_app_name.app"
release_dir="$repo_root/build/release"
dmg="$release_dir/Codenotch-Safe-${safe_version}-universal.dmg"
stage=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codenotch-release-stage.XXXXXX")
trap '/bin/rm -rf "$stage"' EXIT

[[ -d "$safe_app" ]] || {
    print -u2 "verified safe app is missing: $safe_app"
    exit 1
}

/bin/rm -rf "$release_dir"
/bin/mkdir -p "$release_dir"
/usr/bin/ditto --norsrc "$safe_app" "$stage/$safe_app_name.app"
/bin/ln -s /Applications "$stage/Applications"
/bin/cp "$repo_root/LICENSE" "$stage/LICENSE.txt"
/bin/cp "$repo_root/Distribution/FIRST-LAUNCH.txt" "$stage/FIRST-LAUNCH.txt"

/usr/bin/hdiutil create -volname "$safe_app_name" -srcfolder "$stage" \
    -ov -format UDZO "$dmg"
(
    cd "$release_dir"
    /usr/bin/shasum -a 256 "${dmg:t}" > SHA256SUMS.txt
)

print "packaged $dmg"
