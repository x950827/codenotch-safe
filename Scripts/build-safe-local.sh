#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
mode=${1:-build}
build_root="$repo_root/build/safe"
bundle="$build_root/Codenotch.app"
executable="$bundle/Contents/MacOS/Codenotch"
status_line_helper="$bundle/Contents/MacOS/CodenotchClaudeStatusLine"
module_cache="$build_root/module-cache"
helper_module_cache="$build_root/helper-module-cache"

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
    deployment_target=${CODENOTCH_DEPLOYMENT_TARGET:-26.0}
elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    sdk_path=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
    deployment_target=26.0
else
    # This Mac's 26.5 SDK and Command Line Tools compiler have mismatched build
    # revisions. The bundled 15.4 SDK is compatible and the source uses no API
    # newer than it, so local audit builds target 15.0.
    sdk_path=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
    deployment_target=15.0
fi

if [[ ! -d "$sdk_path" ]]; then
    print -u2 "SDK not found: $sdk_path"
    exit 1
fi

/bin/mkdir -p "$module_cache"
common_flags=(
    -parse-as-library
    -module-name Codenotch
    -sdk "$sdk_path"
    -target "arm64-apple-macosx${deployment_target}"
    -module-cache-path "$module_cache"
)

helper_sources=(
    "$repo_root/Sources/Safe/ClaudeStatusLineRecord.swift"
    "$repo_root/Tools/ClaudeStatusLineBridge/main.swift"
)
helper_flags=(
    -parse-as-library
    -module-name CodenotchClaudeStatusLine
    -sdk "$sdk_path"
    -target "arm64-apple-macosx${deployment_target}"
    -module-cache-path "$helper_module_cache"
)

if [[ "$mode" == "--typecheck" ]]; then
    /usr/bin/xcrun swiftc -typecheck "${common_flags[@]}" "${source_files[@]}"
    /bin/mkdir -p "$helper_module_cache"
    /usr/bin/xcrun swiftc -typecheck "${helper_flags[@]}" "${helper_sources[@]}"
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

/bin/rm -rf "$bundle"
/bin/mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

/usr/bin/xcrun swiftc -O "${common_flags[@]}" "${source_files[@]}" \
    -lsqlite3 \
    -o "$executable"
/bin/mkdir -p "$helper_module_cache"
/usr/bin/xcrun swiftc -O "${helper_flags[@]}" "${helper_sources[@]}" \
    -o "$status_line_helper"

/bin/cp "$repo_root/Sources/Assets.xcassets/MenuBarIcon.imageset/menubar-codenotch.svg" \
    "$bundle/Contents/Resources/MenuBarIcon.svg"

/bin/cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>Codenotch Safe</string>
    <key>CFBundleExecutable</key><string>Codenotch</string>
    <key>CFBundleIdentifier</key><string>local.audited.codenotch</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Codenotch Safe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.6.0-safe.11</string>
    <key>CFBundleVersion</key><string>11</string>
    <key>LSMinimumSystemVersion</key><string>$deployment_target</string>
</dict>
</plist>
PLIST

# Documents may be backed by File Provider, which can reattach Finder metadata
# in the tiny interval between clearing attributes and signing. Sign a copy in
# a non-File-Provider directory, then copy the sealed contents back without
# resource metadata. The verifier repeats the copy and validates the signature.
signing_staging=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codenotch-sign.XXXXXX")
trap '/bin/rm -rf "$signing_staging"' EXIT
staged_bundle="$signing_staging/Codenotch.app"
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
