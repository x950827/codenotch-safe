#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
source "$script_dir/safe-release-metadata.sh"

dmg="$repo_root/build/release/Codenotch-Safe-${safe_version}-universal.dmg"
checksums="$repo_root/build/release/SHA256SUMS.txt"
package_script="$script_dir/package-safe-release.sh"

[[ -x "$package_script" ]] || {
    print -u2 "safe release packager is missing"
    exit 1
}
[[ -f "$dmg" && -f "$checksums" ]] || {
    print -u2 "safe release outputs are missing"
    exit 1
}

mount_point=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codenotch-policy-mount.XXXXXX")
device=""
cleanup() {
    if [[ -n "$device" ]]; then
        /usr/bin/hdiutil detach "$device" -quiet || true
    fi
    /bin/rm -rf "$mount_point"
}
trap cleanup EXIT

attach_output=$(/usr/bin/hdiutil attach -readonly -nobrowse \
    -mountpoint "$mount_point" "$dmg")
device=$(print -r -- "$attach_output" | /usr/bin/awk '/^\/dev\// { print $1; exit }')
[[ -n "$device" ]]

app="$mount_point/$safe_app_name.app"
[[ -d "$app" ]]
[[ -L "$mount_point/Applications" ]]
[[ -f "$mount_point/LICENSE.txt" ]]
[[ -f "$mount_point/FIRST-LAUNCH.txt" ]]
/usr/bin/cmp "$repo_root/LICENSE" "$mount_point/LICENSE.txt"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

for binary in \
    "$app/Contents/MacOS/Codenotch" \
    "$app/Contents/MacOS/CodenotchClaudeStatusLine"; do
    slices=$(/usr/bin/lipo -archs "$binary")
    [[ "$slices" == "x86_64 arm64" || "$slices" == "arm64 x86_64" ]]
done

(
    cd "$repo_root/build/release"
    /usr/bin/shasum -a 256 -c SHA256SUMS.txt
)

print "safe packaging policy tests passed"
