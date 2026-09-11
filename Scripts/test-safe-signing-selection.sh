#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
resolver="$script_dir/resolve-safe-signing-identity.sh"
scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codenotch-signing-test.XXXXXX")
trap '/bin/rm -rf "$scratch"' EXIT

fingerprint_a=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
fingerprint_b=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
one_match=$'  1) '$fingerprint_a$' "Codenotch Local Signing"\n     1 valid identities found'
two_matches=$'  1) '$fingerprint_a$' "Codenotch Local Signing"\n  2) '$fingerprint_b$' "Codenotch Local Signing"\n     2 valid identities found'
near_match=$'  1) '$fingerprint_a$' "Codenotch Local Signing Backup"\n     1 valid identities found'

expect_success() {
    local expected=$1 selector=$2 fixture=$3
    local actual
    actual=$(print -r -- "$fixture" | "$resolver" "$selector")
    [[ "$actual" == "$expected" ]] || {
        print -u2 "expected $expected for $selector, got $actual"
        exit 1
    }
}

expect_failure() {
    local selector=$1 fixture=$2 expected_message=$3
    local error_file="$scratch/error"
    if print -r -- "$fixture" | "$resolver" "$selector" 2>"$error_file"; then
        print -u2 "resolver unexpectedly accepted $selector"
        exit 1
    fi
    /usr/bin/grep -Fq "$expected_message" "$error_file" || {
        print -u2 "resolver returned the wrong failure for $selector"
        exit 1
    }
}

expect_success "$fingerprint_a" "Codenotch Local Signing" "$one_match"
expect_success "$fingerprint_a" "$fingerprint_a" "$one_match"
expect_success "$fingerprint_a" "${fingerprint_a:l}" "$one_match"
expect_success "-" "-" ""
expect_failure "Codenotch Local Signing" "$two_matches" "multiple valid code-signing identities match"
expect_failure "Codenotch Local Signing" "$near_match" "no valid code-signing identity matches"
expect_failure "$fingerprint_b" "$one_match" "no valid code-signing identity matches"
expect_failure "Codenotch Local Signing" "" "no valid code-signing identity matches"

print "safe signing identity selection tests passed"
