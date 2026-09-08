#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
mode=${1:-build}
build_root="$repo_root/build/safe"
bundle="$build_root/Codenotch.app"
executable="$bundle/Contents/MacOS/Codenotch"
module_cache="$build_root/module-cache"

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

if [[ "$mode" == "--typecheck" ]]; then
    /usr/bin/xcrun swiftc -typecheck "${common_flags[@]}" "${source_files[@]}"
    exit 0
fi
if [[ "$mode" != "build" ]]; then
    print -u2 "usage: ${0:t} [build|--typecheck]"
    exit 2
fi

/bin/rm -rf "$bundle"
/bin/mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

/usr/bin/xcrun swiftc -O "${common_flags[@]}" "${source_files[@]}" \
    -lsqlite3 \
    -o "$executable"

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
    <key>CFBundleShortVersionString</key><string>1.6.0-safe.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>$deployment_target</string>
</dict>
</plist>
PLIST

# Documents may be backed by File Provider, which adds Finder metadata to new
# directories. codesign correctly rejects that metadata inside an app bundle.
/usr/bin/xattr -cr "$bundle"
/usr/bin/codesign --force --deep --sign - "$bundle"
# File Provider recognizes the freshly signed directory as an app package and
# may attach FinderInfo at that point, so clear package metadata once more.
/usr/bin/xattr -cr "$bundle"
print "built $bundle"
