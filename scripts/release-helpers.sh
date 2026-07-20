#!/bin/sh

RELEASE_LABEL_DEFAULT=0.1.0-alpha.1
RELEASE_ARCHIVE_NAME=GhostTerm.xcarchive
RELEASE_DMG_NAME=GhostTerm-0.1.0-alpha.1-arm64.dmg
RELEASE_STAGE_NAME=GhostTerm-0.1.0-alpha.1-stage

release_fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

release_require_no_arguments() {
    [ "$#" -eq 0 ] || release_fail 'this script accepts no options or positional arguments'
}

release_validate_label() {
    [ -n "$1" ] || release_fail 'RELEASE_LABEL must not be empty'
    [ "$1" = "$RELEASE_LABEL_DEFAULT" ] \
        || release_fail "RELEASE_LABEL must be fixed at $RELEASE_LABEL_DEFAULT"
}

release_validate_team() {
    [ -n "$1" ] || release_fail 'DEVELOPMENT_TEAM must be set'
    printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[A-Z0-9]{10}$' \
        || release_fail 'DEVELOPMENT_TEAM must be a 10-character uppercase Apple team identifier'
}

release_validate_identity() {
    [ -n "$1" ] || release_fail 'CODE_SIGN_IDENTITY must be set'
    case "$1" in
        'Developer ID Application: '*) ;;
        *) release_fail 'CODE_SIGN_IDENTITY must name a Developer ID Application certificate' ;;
    esac
}

release_signature_has_hardened_runtime() {
    release_signature_data=$1

    while IFS= read -r release_signature_line || [ -n "$release_signature_line" ]; do
        case "$release_signature_line" in
            *flags=*runtime*) return 0 ;;
        esac
    done <<EOF
$release_signature_data
EOF

    return 1
}

release_environment_variable_is_set() {
    case "$1" in
        '' | *[!A-Z0-9_]* | [0-9]*) return 1 ;;
        *) ;;
    esac

    eval '[ "${'"$1"'+x}" = x ]'
}

release_reject_secret_environment() {
    for secret_variable in \
        APPLE_ID \
        APPLE_PASSWORD \
        APPLE_APP_SPECIFIC_PASSWORD \
        APPLE_ID_PASSWORD \
        FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD \
        NOTARYTOOL_PASSWORD \
        APPLE_API_KEY \
        APPLE_API_KEY_ID \
        APPLE_API_ISSUER_ID \
        APPSTORE_CONNECT_API_KEY \
        APPSTORE_CONNECT_API_KEY_PATH \
        APPSTORE_CONNECT_KEY_ID \
        APPSTORE_CONNECT_ISSUER_ID \
        APPSTORE_CONNECT_PRIVATE_KEY \
        APPSTORE_CONNECT_PRIVATE_KEY_PATH \
        APPLE_PRIVATE_KEY \
        APPLE_PRIVATE_KEY_PATH \
        ASC_KEY_ID \
        ASC_ISSUER_ID \
        ASC_PRIVATE_KEY \
        ASC_PRIVATE_KEY_PATH \
        PRIVATE_KEY \
        PRIVATE_KEY_PATH
    do
        if release_environment_variable_is_set "$secret_variable"; then
            release_fail "secret environment variable is not accepted: $secret_variable"
        fi
    done
}

release_prepare_output_directory() {
    release_repo_root=$1

    [ -n "$release_repo_root" ] || release_fail 'repository root must not be empty'
    [ "$release_repo_root" != / ] || release_fail 'repository root must not be /'
    [ -d "$release_repo_root" ] || release_fail "repository root is not a directory: $release_repo_root"
    [ ! -L "$release_repo_root" ] || release_fail "repository root must not be a symlink: $release_repo_root"

    release_build_dir=$release_repo_root/.build
    if [ -e "$release_build_dir" ] || [ -L "$release_build_dir" ]; then
        [ ! -L "$release_build_dir" ] || release_fail ".build must not be a symlink: $release_build_dir"
        [ -d "$release_build_dir" ] || release_fail ".build is not a directory: $release_build_dir"
    else
        mkdir "$release_build_dir" || release_fail "could not create .build directory: $release_build_dir"
    fi

    release_build_canonical=$(CDPATH= cd -P "$release_build_dir" && pwd -P) \
        || release_fail "could not resolve .build directory: $release_build_dir"
    [ "$release_build_canonical" = "$release_repo_root/.build" ] \
        || release_fail ".build resolved outside the canonical repository path: $release_build_canonical"

    release_output_dir=$release_build_dir/Release
    if [ -e "$release_output_dir" ] || [ -L "$release_output_dir" ]; then
        [ ! -L "$release_output_dir" ] || release_fail "release directory must not be a symlink: $release_output_dir"
        [ -d "$release_output_dir" ] || release_fail "release path is not a directory: $release_output_dir"
    else
        mkdir "$release_output_dir" || release_fail "could not create release directory: $release_output_dir"
    fi

    release_output_canonical=$(CDPATH= cd -P "$release_output_dir" && pwd -P) \
        || release_fail "could not resolve release directory: $release_output_dir"
    [ "$release_output_canonical" = "$release_repo_root/.build/Release" ] \
        || release_fail "release directory resolved outside the canonical repository path: $release_output_canonical"

    printf '%s\n' "$release_output_canonical"
}

release_assert_generated_path() {
    release_output_dir=$1
    release_candidate=$2

    [ -n "$release_output_dir" ] || release_fail 'release directory must not be empty'
    [ "$release_output_dir" != / ] || release_fail 'release directory must not be /'
    [ -d "$release_output_dir" ] || release_fail "release directory does not exist: $release_output_dir"
    [ ! -L "$release_output_dir" ] || release_fail "release directory must not be a symlink: $release_output_dir"

    release_output_canonical=$(CDPATH= cd -P "$release_output_dir" && pwd -P) \
        || release_fail "could not resolve release directory: $release_output_dir"
    [ "$release_output_canonical" = "$release_output_dir" ] \
        || release_fail "release directory is not canonical: $release_output_dir"

    case "$release_candidate" in
        "$release_output_dir/$RELEASE_ARCHIVE_NAME" | \
        "$release_output_dir/$RELEASE_DMG_NAME" | \
        "$release_output_dir/$RELEASE_STAGE_NAME") ;;
        *) release_fail "refusing to remove non-generated release path: $release_candidate" ;;
    esac
}

release_remove_generated_directory() {
    release_output_dir=$1
    release_candidate=$2

    release_assert_generated_path "$release_output_dir" "$release_candidate"
    if [ -e "$release_candidate" ] || [ -L "$release_candidate" ]; then
        [ ! -L "$release_candidate" ] || release_fail "refusing to remove symlinked generated path: $release_candidate"
        [ -d "$release_candidate" ] || release_fail "generated directory path is not a directory: $release_candidate"
        printf 'cleanup: removing previous generated directory: %s\n' "$release_candidate"
        rm -rf "$release_candidate"
    fi
}

release_remove_generated_file() {
    release_output_dir=$1
    release_candidate=$2

    release_assert_generated_path "$release_output_dir" "$release_candidate"
    if [ -e "$release_candidate" ] || [ -L "$release_candidate" ]; then
        [ ! -L "$release_candidate" ] || release_fail "refusing to remove symlinked generated path: $release_candidate"
        [ -f "$release_candidate" ] || release_fail "generated file path is not a regular file: $release_candidate"
        printf 'cleanup: removing previous generated file: %s\n' "$release_candidate"
        rm -f "$release_candidate"
    fi
}
