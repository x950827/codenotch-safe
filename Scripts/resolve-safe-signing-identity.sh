#!/bin/zsh
set -euo pipefail

selector=${1:-Codenotch Local Signing}
if [[ "$selector" == "-" ]]; then
    print -r -- "-"
    exit 0
fi

selector_is_fingerprint=false
if [[ ${#selector} -eq 40 && "$selector" != *[^[:xdigit:]]* ]]; then
    selector_is_fingerprint=true
fi

identity_pattern='^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"([^"]+)"[[:space:]]*$'
matches=()
while IFS= read -r line; do
    if [[ "$line" =~ $identity_pattern ]]; then
        fingerprint=${match[1]:u}
        identity_name=${match[2]}
        if [[ "$selector_is_fingerprint" == true ]]; then
            [[ "$fingerprint" == "${selector:u}" ]] && matches+=("$fingerprint")
        else
            [[ "$identity_name" == "$selector" ]] && matches+=("$fingerprint")
        fi
    fi
done

case ${#matches[@]} in
    1) print -r -- "${matches[1]}" ;;
    0)
        print -u2 "no valid code-signing identity matches: $selector"
        exit 1
        ;;
    *)
        print -u2 "multiple valid code-signing identities match: $selector"
        exit 1
        ;;
esac
