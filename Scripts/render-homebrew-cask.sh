#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
source "$script_dir/safe-release-metadata.sh"

template="$repo_root/Distribution/Casks/codenotch-safe.rb.in"
checksums="$repo_root/build/release/SHA256SUMS.txt"
output_dir="$repo_root/build/homebrew-tap/Casks"
cask="$output_dir/codenotch-safe.rb"

[[ -f "$template" && -f "$checksums" ]] || {
    print -u2 "cask template or release checksum is missing"
    exit 1
}
sha256=$(/usr/bin/awk 'NF == 2 { print $1; exit }' "$checksums")
[[ ${#sha256} -eq 64 && "$sha256" != *[^0-9a-fA-F]* ]] || {
    print -u2 "invalid DMG checksum"
    exit 1
}

/bin/mkdir -p "$output_dir"
/usr/bin/sed -e "s/__VERSION__/$safe_version/g" -e "s/__SHA256__/$sha256/g" \
    "$template" > "$cask"
if /usr/bin/grep -Eq '__VERSION__|__SHA256__' "$cask"; then
    print -u2 "cask template placeholders remain"
    exit 1
fi

print "rendered $cask"
