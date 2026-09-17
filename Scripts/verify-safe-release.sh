#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
source "$script_dir/safe-release-metadata.sh"

dmg=${1:-"$repo_root/build/release/Codenotch-Safe-${safe_version}-universal.dmg"}
checksums=${2:-"${dmg:h}/SHA256SUMS.txt"}
[[ -f "$dmg" && -f "$checksums" ]] || {
    print -u2 "safe release DMG or checksum is missing"
    exit 1
}

mount_point=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codenotch-release-mount.XXXXXX")
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
[[ -n "$device" ]] || {
    print -u2 "unable to identify mounted DMG device"
    exit 1
}

app="$mount_point/$safe_app_name.app"
[[ -d "$app" ]] || { print -u2 "DMG app is missing"; exit 1; }
[[ -L "$mount_point/Applications" ]] || { print -u2 "Applications link is missing"; exit 1; }
[[ -f "$mount_point/LICENSE.txt" ]] || { print -u2 "DMG license is missing"; exit 1; }
[[ -f "$mount_point/FIRST-LAUNCH.txt" ]] || { print -u2 "first-launch guide is missing"; exit 1; }

/usr/bin/cmp "$repo_root/LICENSE" "$mount_point/LICENSE.txt"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
for binary in \
    "$app/Contents/MacOS/Codenotch" \
    "$app/Contents/MacOS/CodenotchClaudeStatusLine"; do
    slices=$(/usr/bin/lipo -archs "$binary")
    [[ "$slices" == "x86_64 arm64" || "$slices" == "arm64 x86_64" ]] || {
        print -u2 "DMG contains a non-universal executable: $binary ($slices)"
        exit 1
    }
done

(
    cd "${checksums:h}"
    /usr/bin/shasum -a 256 -c "${checksums:t}"
)

print "safe release verification passed"
