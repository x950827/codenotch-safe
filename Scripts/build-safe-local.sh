#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
source "$script_dir/safe-release-metadata.sh"

mode=${1:-build}
deployment_target=15.0
build_root="$repo_root/build/safe"
bundle="$build_root/$safe_app_name.app"
executable="$bundle/Contents/MacOS/Codenotch"
status_line_helper="$bundle/Contents/MacOS/CodenotchClaudeStatusLine"
architectures=(arm64 x86_64)

source_files=()
while IFS= read -r -d '' source; do
    source_files+=("$repo_root/$source")
done < <("$script_dir/safe-source-list.sh")

if (( ${#source_files[@]} == 0 )); then
    print -u2 "safe source list is empty"
    exit 1
fi

if [[ -n ${CODENOTCH_SDK_PATH:-} ]]; then
    sdk_path="$CODENOTCH_SDK_PATH"
elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    sdk_path=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
else
    # The installed Command Line Tools compiler matches this bundled SDK.
    # Release slices still target macOS 15.0.
    sdk_path=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi

if [[ ! -d "$sdk_path" ]]; then
    print -u2 "SDK not found: $sdk_path"
    exit 1
fi

helper_sources=(
    "$repo_root/Sources/Safe/ClaudeStatusLineRecord.swift"
    "$repo_root/Tools/ClaudeStatusLineBridge/main.swift"
)

if [[ "$mode" == "--typecheck" ]]; then
    typecheck_root="$build_root/typecheck"
    /bin/rm -rf "$typecheck_root"
    for architecture in "${architectures[@]}"; do
        arch_root="$typecheck_root/$architecture"
        /bin/mkdir -p "$arch_root/main-module-cache" "$arch_root/helper-module-cache"
        /usr/bin/xcrun swiftc -typecheck -parse-as-library -module-name Codenotch \
            -sdk "$sdk_path" -target "${architecture}-apple-macosx${deployment_target}" \
            -module-cache-path "$arch_root/main-module-cache" \
            "${source_files[@]}"
        /usr/bin/xcrun swiftc -typecheck -parse-as-library \
            -module-name CodenotchClaudeStatusLine \
            -sdk "$sdk_path" -target "${architecture}-apple-macosx${deployment_target}" \
            -module-cache-path "$arch_root/helper-module-cache" \
            "${helper_sources[@]}"
    done
    exit 0
fi
if [[ "$mode" != "build" ]]; then
    print -u2 "usage: ${0:t} [build|--typecheck]"
    exit 2
fi

requested_signing_identity=${CODENOTCH_SIGNING_IDENTITY:-Codenotch Local Signing}
if [[ "$requested_signing_identity" == "-" ]]; then
    signing_identity=$("$script_dir/resolve-safe-signing-identity.sh" "-" </dev/null)
    signing_mode=adhoc
else
    valid_identities=$(/usr/bin/security find-identity -v -p codesigning)
    signing_identity=$(print -r -- "$valid_identities" \
        | "$script_dir/resolve-safe-signing-identity.sh" "$requested_signing_identity")
    signing_mode=certificate
fi

/bin/rm -rf "$build_root"
/bin/mkdir -p "$build_root"

for architecture in "${architectures[@]}"; do
    arch_root="$build_root/$architecture"
    /bin/mkdir -p "$arch_root/main-module-cache" "$arch_root/helper-module-cache"
    /usr/bin/xcrun swiftc -O -parse-as-library -module-name Codenotch \
        -sdk "$sdk_path" -target "${architecture}-apple-macosx${deployment_target}" \
        -module-cache-path "$arch_root/main-module-cache" \
        "${source_files[@]}" -lsqlite3 -o "$arch_root/Codenotch"
    /usr/bin/xcrun swiftc -O -parse-as-library -module-name CodenotchClaudeStatusLine \
        -sdk "$sdk_path" -target "${architecture}-apple-macosx${deployment_target}" \
        -module-cache-path "$arch_root/helper-module-cache" \
        "${helper_sources[@]}" -o "$arch_root/CodenotchClaudeStatusLine"
done

/bin/mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
/usr/bin/lipo -create "$build_root/arm64/Codenotch" "$build_root/x86_64/Codenotch" \
    -output "$executable"
/usr/bin/lipo -create "$build_root/arm64/CodenotchClaudeStatusLine" \
    "$build_root/x86_64/CodenotchClaudeStatusLine" -output "$status_line_helper"

/bin/cp "$repo_root/Sources/Assets.xcassets/MenuBarIcon.imageset/menubar-codenotch.svg" \
    "$bundle/Contents/Resources/MenuBarIcon.svg"
/bin/cp "$repo_root/Sources/Resources/LICENSE.txt" \
    "$bundle/Contents/Resources/LICENSE.txt"

# Assemble the ICNS container directly from the audited PNGs. Copying the
# asset-catalog directory with `ditto` tries to reproduce File Provider
# provenance attributes and fails inside Documents; the ICNS format stores
# these PNG payloads verbatim behind a type and big-endian length.
icon_source="$repo_root/Sources/Assets.xcassets/AppIcon.appiconset"
icon_output="$bundle/Contents/Resources/AppIcon.icns"
icon_types=(icp4 icp5 icp6 ic07 ic08 ic09 ic10)
icon_files=(
    icon_16x16.png
    icon_32x32.png
    icon_32x32@2x.png
    icon_128x128.png
    icon_256x256.png
    icon_512x512.png
    icon_512x512@2x.png
)
icon_length=8
for icon_file in "${icon_files[@]}"; do
    (( icon_length += 8 + $(/usr/bin/stat -f %z "$icon_source/$icon_file") ))
done
{
    print -rn -- icns
    printf '%08x' "$icon_length" | /usr/bin/xxd -r -p
    for index in {1..${#icon_files[@]}}; do
        icon_file="$icon_source/${icon_files[$index]}"
        element_length=$(( 8 + $(/usr/bin/stat -f %z "$icon_file") ))
        print -rn -- "${icon_types[$index]}"
        printf '%08x' "$element_length" | /usr/bin/xxd -r -p
        /bin/cat "$icon_file"
    done
} > "$icon_output"

/bin/cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>$safe_app_name</string>
    <key>CFBundleExecutable</key><string>Codenotch</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundleIdentifier</key><string>local.audited.codenotch</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$safe_app_name</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$safe_version</string>
    <key>CFBundleVersion</key><string>$safe_build</string>
    <key>LSMinimumSystemVersion</key><string>$deployment_target</string>
    <key>NSHumanReadableCopyright</key><string>Copyright (c) 2026 Vinz. Codenotch Safe modifications distributed under the MIT License.</string>
</dict>
</plist>
PLIST

# Documents may be backed by File Provider, which can reattach Finder metadata
# in the tiny interval between clearing attributes and signing. Sign a copy in
# a non-File-Provider directory, then copy the sealed contents back without
# resource metadata. The verifier repeats the copy and validates the signature.
signing_staging=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codenotch-sign.XXXXXX")
trap '/bin/rm -rf "$signing_staging"' EXIT
staged_bundle="$signing_staging/$safe_app_name.app"
/usr/bin/ditto --norsrc "$bundle" "$staged_bundle"
/usr/bin/xattr -cr "$staged_bundle"
/usr/bin/codesign --force --deep --sign "$signing_identity" "$staged_bundle"
/bin/rm -rf "$bundle"
/usr/bin/ditto --norsrc "$staged_bundle" "$bundle"

evidence="$build_root/verification"
/bin/mkdir -p "$evidence"
print -r -- "$signing_mode" > "$evidence/signing-mode.txt"
print -r -- "$signing_identity" > "$evidence/signing-identity.txt"
print "built $bundle ($signing_mode signing)"
