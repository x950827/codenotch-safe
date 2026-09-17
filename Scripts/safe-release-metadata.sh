#!/bin/zsh

safe_metadata_source=${(%):-%N}
safe_metadata_dir=${safe_metadata_source:A:h}
safe_repo_root=${safe_metadata_dir:h}

safe_version=$(/usr/bin/awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' \
    "$safe_repo_root/project.yml")
safe_build=$(/usr/bin/awk -F'"' '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' \
    "$safe_repo_root/project.yml")
safe_tag="v${safe_version}"
safe_app_name="Codenotch Safe"

[[ -n "$safe_version" && -n "$safe_build" ]] || {
    print -u2 "safe release metadata is missing from project.yml"
    return 1 2>/dev/null || exit 1
}

safe_validate_tag() {
    [[ ${1:-} == "$safe_tag" ]] || {
        print -u2 "release tag ${1:-<missing>} does not match $safe_tag"
        return 1
    }
}
