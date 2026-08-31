#!/bin/sh

RELEASE_LABEL_DEFAULT=0.1.2
RELEASE_ARCHIVE_NAME=QuickTTY.xcarchive
RELEASE_DMG_NAME=QuickTTY-0.1.2-arm64.dmg
RELEASE_STAGE_NAME=QuickTTY-0.1.2-stage
RELEASE_NOTARY_RESULT_NAME=$RELEASE_DMG_NAME.notary-result.json
RELEASE_APPCAST_DIRECTORY_NAME=appcast
RELEASE_APPCAST_NAME=appcast.xml
RELEASE_BETA_APPCAST_RELATIVE_PATH=docs/appcasts/beta.xml
RELEASE_BETA_APPCAST_RAW_URL=https://raw.githubusercontent.com/dntsk/quicktty/master/docs/appcasts/beta.xml
RELEASE_GITHUB_RELEASE_DOWNLOAD_BASE=https://github.com/dntsk/quicktty/releases/download
RELEASE_FIND_PATH=/usr/bin/find
RELEASE_MKTEMP_PATH=/usr/bin/mktemp
RELEASE_CHMOD_PATH=/bin/chmod
RELEASE_MKDIR_PATH=/bin/mkdir
RELEASE_RM_PATH=/bin/rm
RELEASE_NESTED_CODE_LIST=
RELEASE_NESTED_CODE_TMPDIR=

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

release_appcast_download_url_prefix() {
    printf '%s\n' "$RELEASE_GITHUB_RELEASE_DOWNLOAD_BASE/v$RELEASE_LABEL_DEFAULT/"
}

release_verify_appcast() {
    release_appcast_path=$1
    release_dmg_path=$2
    release_stat_path=$3
    release_grep_path=$4

    [ -f "$release_appcast_path" ] \
        || release_fail "appcast is not a regular file: $release_appcast_path"
    [ ! -L "$release_appcast_path" ] \
        || release_fail "appcast must not be a symlink: $release_appcast_path"
    [ -f "$release_dmg_path" ] \
        || release_fail "DMG is not a regular file: $release_dmg_path"
    [ ! -L "$release_dmg_path" ] \
        || release_fail "DMG must not be a symlink: $release_dmg_path"

    release_dmg_size=$("$release_stat_path" -f '%z' "$release_dmg_path") \
        || release_fail "could not determine DMG size for appcast: $release_dmg_path"
    release_expected_enclosure_url="<enclosure url=\"$(release_appcast_download_url_prefix)$RELEASE_DMG_NAME\""
    "$release_grep_path" -F "$release_expected_enclosure_url" "$release_appcast_path" >/dev/null \
        || release_fail "appcast enclosure URL does not match the final DMG: $release_appcast_path"
    "$release_grep_path" -F "length=\"$release_dmg_size\"" "$release_appcast_path" >/dev/null \
        || release_fail "appcast enclosure length does not match the final DMG: $release_appcast_path"
    "$release_grep_path" -F 'type="application/octet-stream"' "$release_appcast_path" >/dev/null \
        || release_fail "appcast enclosure type is invalid: $release_appcast_path"
    "$release_grep_path" -F 'sparkle:edSignature="' "$release_appcast_path" >/dev/null \
        || release_fail "appcast enclosure is missing a Sparkle Ed25519 signature: $release_appcast_path"
}

release_beta_appcast_path() {
    release_beta_repo_root=$1

    [ -n "$release_beta_repo_root" ] || release_fail 'repository root must not be empty'
    case "$release_beta_repo_root" in
        /*) ;;
        *) release_fail "repository root must be absolute: $release_beta_repo_root" ;;
    esac

    printf '%s/%s\n' "$release_beta_repo_root" "$RELEASE_BETA_APPCAST_RELATIVE_PATH"
}

release_validate_team() {
    [ -n "$1" ] || release_fail 'DEVELOPMENT_TEAM must be set'
    [ "${#1}" -eq 10 ] || release_fail 'DEVELOPMENT_TEAM must be a 10-character uppercase Apple team identifier'
    case "$1" in
        *[!A-Z0-9]*) release_fail 'DEVELOPMENT_TEAM must be a 10-character uppercase Apple team identifier' ;;
    esac
}

release_validate_identity() {
    [ -n "$1" ] || release_fail 'CODE_SIGN_IDENTITY must be set'
    case "$1" in
        'Developer ID Application: '*) ;;
        *) release_fail 'CODE_SIGN_IDENTITY must name a Developer ID Application certificate' ;;
    esac
}

release_signature_has_exact_line() {
    release_signature_data=$1
    release_expected_line=$2

    while IFS= read -r release_signature_line || [ -n "$release_signature_line" ]; do
        [ "$release_signature_line" = "$release_expected_line" ] && return 0
    done <<EOF
$release_signature_data
EOF

    return 1
}

release_signature_has_nonempty_prefix() {
    release_signature_data=$1
    release_expected_prefix=$2

    while IFS= read -r release_signature_line || [ -n "$release_signature_line" ]; do
        case "$release_signature_line" in
            "$release_expected_prefix"?*) return 0 ;;
        esac
    done <<EOF
$release_signature_data
EOF

    return 1
}

release_signature_has_hardened_runtime() {
    release_signature_data=$1

    while IFS= read -r release_signature_line || [ -n "$release_signature_line" ]; do
        case "$release_signature_line" in
            CodeDirectory\ *flags=*) ;;
            *) continue ;;
        esac

        release_flags_field=${release_signature_line#*flags=}
        case "$release_flags_field" in
            *\(*) ;;
            *) continue ;;
        esac
        release_flags_value=${release_flags_field%%\(*}
        case "$release_flags_value" in
            0x*) release_flags_hex=${release_flags_value#0x} ;;
            *) continue ;;
        esac
        [ -n "$release_flags_hex" ] || continue
        case "$release_flags_hex" in
            *[!0123456789abcdefABCDEF]*) continue ;;
        esac
        release_flags_list=${release_flags_field#"$release_flags_value"\(}
        case "$release_flags_list" in
            *\)*) release_flags_list=${release_flags_list%%\)*} ;;
            *) continue ;;
        esac

        case ",$release_flags_list," in
            *,runtime,*) return 0 ;;
        esac
    done <<EOF
$release_signature_data
EOF

    return 1
}

release_verify_signature_metadata() {
    release_signed_path=$1
    release_expected_identifier=$2
    release_require_runtime=$3
    release_codesign_path=$4
    release_expected_identity=$5
    release_expected_team=$6

    release_signature_data=$("$release_codesign_path" -d -vvv "$release_signed_path" 2>&1) \
        || release_fail "could not display code-signature metadata: $release_signed_path"
    release_signature_has_exact_line "$release_signature_data" "Authority=$release_expected_identity" \
        || release_fail "signature authority does not match CODE_SIGN_IDENTITY: $release_signed_path"
    release_signature_has_exact_line "$release_signature_data" "TeamIdentifier=$release_expected_team" \
        || release_fail "signature team does not match DEVELOPMENT_TEAM: $release_signed_path"
    release_signature_has_nonempty_prefix "$release_signature_data" 'Timestamp=' \
        || release_fail "signature has no secure timestamp: $release_signed_path"

    if [ -n "$release_expected_identifier" ]; then
        release_signature_has_exact_line "$release_signature_data" "Identifier=$release_expected_identifier" \
            || release_fail "signature identifier does not match bundle identifier: $release_signed_path"
    fi

    if [ "$release_require_runtime" = yes ]; then
        release_signature_has_hardened_runtime "$release_signature_data" \
            || release_fail "hardened runtime flag is missing: $release_signed_path"
    fi
}

release_require_path_without_control_characters() {
    release_checked_path=$1
    release_checked_description=$2

    if LC_ALL=C printf '%s' "$release_checked_path" | /usr/bin/grep -q '[[:cntrl:]]'; then
        release_fail "$release_checked_description contains control characters"
    fi
}

release_require_real_directory() {
    release_real_directory_path=$1
    release_real_directory_description=$2

    release_require_path_without_control_characters \
        "$release_real_directory_path" "$release_real_directory_description path"
    [ -d "$release_real_directory_path" ] \
        || release_fail "$release_real_directory_description is not a directory: $release_real_directory_path"
    [ ! -L "$release_real_directory_path" ] \
        || release_fail "$release_real_directory_description must not be a symlink: $release_real_directory_path"
}

release_source_tree_state() {
    release_source_repository=$1
    release_git_path=$2

    release_git_status=$("$release_git_path" -C "$release_source_repository" \
        status --porcelain=v1 --untracked-files=all --ignore-submodules=none) || return 1
    if [ -n "$release_git_status" ]; then
        printf '%s\n' dirty
    else
        printf '%s\n' clean
    fi
}

release_require_canonical_directory() {
    release_directory_path=$1
    release_directory_description=$2

    [ -d "$release_directory_path" ] \
        || release_fail "$release_directory_description is not a directory: $release_directory_path"
    [ ! -L "$release_directory_path" ] \
        || release_fail "$release_directory_description must not be a symlink: $release_directory_path"
    release_directory_canonical=$(CDPATH= cd -P "$release_directory_path" && pwd -P) \
        || release_fail "could not resolve $release_directory_description: $release_directory_path"
    [ "$release_directory_canonical" = "$release_directory_path" ] \
        || release_fail "$release_directory_description is not canonical: $release_directory_path"
}

release_prepare_ghostty_generated_resource_parent() {
    release_resource_repository=$1
    release_ghostty_directory=$release_resource_repository/Vendor/ghostty
    release_zig_out_directory=$release_ghostty_directory/zig-out
    release_share_directory=$release_zig_out_directory/share

    release_require_canonical_directory "$release_resource_repository" 'repository root'
    release_require_canonical_directory "$release_resource_repository/Vendor" 'Vendor directory'
    release_require_canonical_directory "$release_ghostty_directory" 'Ghostty source directory'

    if [ ! -e "$release_zig_out_directory" ] && [ ! -L "$release_zig_out_directory" ]; then
        return 0
    fi
    release_require_canonical_directory "$release_zig_out_directory" 'Ghostty zig-out directory'

    if [ ! -e "$release_share_directory" ] && [ ! -L "$release_share_directory" ]; then
        return 0
    fi
    release_require_canonical_directory "$release_share_directory" 'Ghostty generated share directory'
}

release_remove_ghostty_generated_resource_directory() {
    release_resource_repository=$1
    release_resource_candidate=$2
    release_terminfo_directory=$release_resource_repository/Vendor/ghostty/zig-out/share/terminfo
    release_ghostty_resource_directory=$release_resource_repository/Vendor/ghostty/zig-out/share/ghostty

    case "$release_resource_candidate" in
        "$release_terminfo_directory" | "$release_ghostty_resource_directory") ;;
        *) release_fail "refusing to remove non-generated Ghostty resource path: $release_resource_candidate" ;;
    esac

    release_prepare_ghostty_generated_resource_parent "$release_resource_repository"

    if [ -e "$release_resource_candidate" ] || [ -L "$release_resource_candidate" ]; then
        release_require_canonical_directory "$release_resource_candidate" 'Ghostty generated resource directory'
        printf 'cleanup: removing generated Ghostty runtime resources: %s\n' "$release_resource_candidate"
        "$RELEASE_RM_PATH" -rf "$release_resource_candidate"
    fi
}

release_force_clean_ghostty_generated_resources() {
    release_resource_repository=$1
    release_resource_share_directory=$release_resource_repository/Vendor/ghostty/zig-out/share

    release_remove_ghostty_generated_resource_directory \
        "$release_resource_repository" "$release_resource_share_directory/terminfo"
    release_remove_ghostty_generated_resource_directory \
        "$release_resource_repository" "$release_resource_share_directory/ghostty"
}

release_verify_ghostty_generated_resources() {
    release_resource_repository=$1
    release_resource_share_directory=$release_resource_repository/Vendor/ghostty/zig-out/share
    release_terminfo_directory=$release_resource_share_directory/terminfo
    release_ghostty_resource_directory=$release_resource_share_directory/ghostty

    release_prepare_ghostty_generated_resource_parent "$release_resource_repository"
    release_require_canonical_directory "$release_resource_share_directory" 'Ghostty generated share directory'
    release_require_canonical_directory "$release_terminfo_directory" 'Ghostty generated terminfo directory'
    release_require_canonical_directory "$release_terminfo_directory/78" 'Ghostty generated terminfo entry directory'
    release_require_canonical_directory "$release_ghostty_resource_directory" 'Ghostty generated resource directory'
    release_require_canonical_directory \
        "$release_ghostty_resource_directory/shell-integration" 'Ghostty generated shell integration directory'
    release_require_canonical_directory "$release_ghostty_resource_directory/themes" 'Ghostty generated themes directory'
    [ -f "$release_terminfo_directory/78/xterm-ghostty" ] \
        || release_fail "missing generated Ghostty terminfo sentinel: $release_terminfo_directory/78/xterm-ghostty"
    [ ! -L "$release_terminfo_directory/78/xterm-ghostty" ] \
        || release_fail "generated Ghostty terminfo sentinel must not be a symlink: $release_terminfo_directory/78/xterm-ghostty"
    [ -f "$release_ghostty_resource_directory/shell-integration/bash/ghostty.bash" ] \
        || release_fail "missing generated Ghostty shell integration sentinel: $release_ghostty_resource_directory/shell-integration/bash/ghostty.bash"
    [ ! -L "$release_ghostty_resource_directory/shell-integration/bash/ghostty.bash" ] \
        || release_fail "generated Ghostty shell integration sentinel must not be a symlink: $release_ghostty_resource_directory/shell-integration/bash/ghostty.bash"
}

release_require_empty_or_absent_directory() {
    release_directory_path=$1

    if [ -e "$release_directory_path" ] || [ -L "$release_directory_path" ]; then
        [ ! -L "$release_directory_path" ] \
            || release_fail "nested code directory must not be a symlink: $release_directory_path"
        [ -d "$release_directory_path" ] \
            || release_fail "nested code path is not a directory: $release_directory_path"
        release_directory_entry=$("$RELEASE_FIND_PATH" "$release_directory_path" -mindepth 1 -print -quit) \
            || release_fail "could not inspect nested code directory: $release_directory_path"
        [ -z "$release_directory_entry" ] \
            || release_fail "unexpected nested code directory contents: $release_directory_path"
    fi
}

release_verify_cli_helper_layout() {
    release_helper_app_bundle=$1
    release_helpers_directory=$release_helper_app_bundle/Contents/Helpers
    release_cli_helper=$release_helpers_directory/quicktty

    [ -d "$release_helpers_directory" ] \
        || release_fail "CLI helper directory is missing: $release_helpers_directory"
    [ ! -L "$release_helpers_directory" ] \
        || release_fail "CLI helper directory must not be a symlink: $release_helpers_directory"
    [ -f "$release_cli_helper" ] \
        || release_fail "CLI helper is missing or not a regular file: $release_cli_helper"
    [ ! -L "$release_cli_helper" ] \
        || release_fail "CLI helper must not be a symlink: $release_cli_helper"
    [ -x "$release_cli_helper" ] \
        || release_fail "CLI helper is not executable: $release_cli_helper"

    release_helper_entry_count=0
    for release_helper_entry in "$release_helpers_directory"/* "$release_helpers_directory"/.*; do
        case "$release_helper_entry" in
            "$release_helpers_directory/." | "$release_helpers_directory/..") continue ;;
        esac
        [ -e "$release_helper_entry" ] || [ -L "$release_helper_entry" ] || continue
        [ "$release_helper_entry" = "$release_cli_helper" ] \
            || release_fail "unexpected entry in Contents/Helpers: $release_helper_entry"
        release_helper_entry_count=$((release_helper_entry_count + 1))
    done
    [ "$release_helper_entry_count" -eq 1 ] \
        || release_fail "Contents/Helpers must contain exactly one CLI helper: $release_helpers_directory"
}

release_verify_cli_helper_artifact() {
    release_helper_app_bundle=$1
    release_helper_file_path=$2
    release_helper_lipo_path=$3
    release_helper_stat_path=$4
    release_cli_helper=$release_helper_app_bundle/Contents/Helpers/quicktty

    release_verify_cli_helper_layout "$release_helper_app_bundle"

    release_helper_mode=$("$release_helper_stat_path" -f '%Lp' "$release_cli_helper") \
        || release_fail "could not determine CLI helper mode: $release_cli_helper"
    [ "$release_helper_mode" = 755 ] \
        || release_fail "CLI helper mode must be 0755; found: $release_helper_mode"

    release_helper_description=$("$release_helper_file_path" -b "$release_cli_helper") \
        || release_fail "could not inspect CLI helper file type: $release_cli_helper"
    case "$release_helper_description" in
        'Mach-O 64-bit executable arm64'*) ;;
        *) release_fail "CLI helper must be an arm64 Mach-O executable: $release_cli_helper" ;;
    esac

    release_helper_architectures=$("$release_helper_lipo_path" -archs "$release_cli_helper") \
        || release_fail "could not determine CLI helper architectures: $release_cli_helper"
    [ "$release_helper_architectures" = arm64 ] \
        || release_fail "CLI helper must contain arm64 only; found: $release_helper_architectures"
}

release_verify_frameworks_layout() {
    release_frameworks_app_bundle=$1
    release_frameworks_directory=$release_frameworks_app_bundle/Contents/Frameworks
    release_sparkle_framework=$release_frameworks_directory/Sparkle.framework

    release_require_path_without_control_characters \
        "$release_frameworks_app_bundle" 'app bundle path'
    if [ ! -e "$release_frameworks_directory" ] && [ ! -L "$release_frameworks_directory" ]; then
        return 0
    fi

    release_require_real_directory "$release_frameworks_directory" 'app Frameworks directory'
    for release_frameworks_entry in \
        "$release_frameworks_directory"/* \
        "$release_frameworks_directory"/.[!.]* \
        "$release_frameworks_directory"/..?*
    do
        [ -e "$release_frameworks_entry" ] || [ -L "$release_frameworks_entry" ] || continue
        release_require_path_without_control_characters \
            "$release_frameworks_entry" 'Frameworks entry path'
        case "$release_frameworks_entry" in
            "$release_sparkle_framework")
                release_require_real_directory "$release_frameworks_entry" 'Sparkle framework'
                ;;
            *)
                release_fail "unexpected entry in Contents/Frameworks: $release_frameworks_entry"
                ;;
        esac
    done
}

release_verify_sparkle_signing_layout() {
    release_sparkle_app_bundle=$1
    release_sparkle_frameworks=$release_sparkle_app_bundle/Contents/Frameworks
    release_sparkle_framework=$release_sparkle_frameworks/Sparkle.framework
    release_sparkle_versions=$release_sparkle_framework/Versions
    release_sparkle_version=$release_sparkle_versions/B
    release_sparkle_xpc_services=$release_sparkle_version/XPCServices

    release_verify_frameworks_layout "$release_sparkle_app_bundle"
    release_require_real_directory "$release_sparkle_framework" 'Sparkle framework'
    release_require_real_directory "$release_sparkle_versions" 'Sparkle Versions directory'
    release_require_real_directory "$release_sparkle_version" 'Sparkle version directory'
    release_require_real_directory "$release_sparkle_xpc_services" 'Sparkle XPCServices directory'
    release_require_real_directory \
        "$release_sparkle_xpc_services/Installer.xpc" 'Sparkle Installer XPC bundle'
    release_require_real_directory \
        "$release_sparkle_xpc_services/Downloader.xpc" 'Sparkle Downloader XPC bundle'
    release_require_real_directory "$release_sparkle_version/Updater.app" 'Sparkle Updater app bundle'

    for release_sparkle_executable in \
        "$release_sparkle_version/Autoupdate" \
        "$release_sparkle_version/Sparkle" \
        "$release_sparkle_xpc_services/Installer.xpc/Contents/MacOS/Installer" \
        "$release_sparkle_xpc_services/Downloader.xpc/Contents/MacOS/Downloader" \
        "$release_sparkle_version/Updater.app/Contents/MacOS/Updater"
    do
        release_require_path_without_control_characters \
            "$release_sparkle_executable" 'Sparkle executable path'
        [ -f "$release_sparkle_executable" ] && [ ! -L "$release_sparkle_executable" ] \
            && [ -x "$release_sparkle_executable" ] \
            || release_fail "Sparkle executable is unsafe: $release_sparkle_executable"
    done
}

release_cleanup_nested_code_list() {
    [ -n "$RELEASE_NESTED_CODE_LIST" ] || return 0
    case "$RELEASE_NESTED_CODE_LIST" in
        "$RELEASE_NESTED_CODE_TMPDIR"/quicktty-nested-code.*) ;;
        *)
            printf 'error: refusing to remove unexpected nested code list: %s\n' \
                "$RELEASE_NESTED_CODE_LIST" >&2
            return 1
            ;;
    esac

    if [ -e "$RELEASE_NESTED_CODE_LIST" ] || [ -L "$RELEASE_NESTED_CODE_LIST" ]; then
        "$RELEASE_RM_PATH" -f -- "$RELEASE_NESTED_CODE_LIST" || return 1
    fi
    RELEASE_NESTED_CODE_LIST=
    RELEASE_NESTED_CODE_TMPDIR=
}

release_create_nested_code_list() {
    release_nested_tmpdir_input=${TMPDIR:-/tmp}
    release_require_path_without_control_characters "$release_nested_tmpdir_input" 'TMPDIR path'
    case "$release_nested_tmpdir_input" in
        /*) ;;
        *) release_fail "TMPDIR must be absolute: $release_nested_tmpdir_input" ;;
    esac
    [ -d "$release_nested_tmpdir_input" ] \
        || release_fail "TMPDIR is not a directory: $release_nested_tmpdir_input"
    RELEASE_NESTED_CODE_TMPDIR=$(CDPATH= cd -P "$release_nested_tmpdir_input" && pwd -P) \
        || release_fail "could not resolve TMPDIR: $release_nested_tmpdir_input"
    [ "$RELEASE_NESTED_CODE_TMPDIR" != / ] \
        || release_fail 'TMPDIR must not resolve to /'

    RELEASE_NESTED_CODE_LIST=$(umask 077 && \
        "$RELEASE_MKTEMP_PATH" "$RELEASE_NESTED_CODE_TMPDIR/quicktty-nested-code.XXXXXX") \
        || release_fail "could not create nested code list under TMPDIR: $RELEASE_NESTED_CODE_TMPDIR"
    case "$RELEASE_NESTED_CODE_LIST" in
        "$RELEASE_NESTED_CODE_TMPDIR"/quicktty-nested-code.*) ;;
        *)
            release_cleanup_nested_code_list
            release_fail 'nested code list has an unexpected path'
            ;;
    esac
    "$RELEASE_CHMOD_PATH" 600 "$RELEASE_NESTED_CODE_LIST" || {
        release_cleanup_nested_code_list
        release_fail 'could not secure nested code list'
    }
}

release_verify_nested_code_recursively() {
    release_nested_app_bundle=$1
    release_nested_codesign_path=$2
    release_nested_file_path=$3
    release_nested_expected_identity=$4
    release_nested_expected_team=$5
    release_nested_frameworks=$release_nested_app_bundle/Contents/Frameworks
    release_nested_sparkle=$release_nested_frameworks/Sparkle.framework/Versions/B

    release_verify_sparkle_signing_layout "$release_nested_app_bundle"
    release_create_nested_code_list
    if ! "$RELEASE_FIND_PATH" "$release_nested_frameworks" -type f -print0 \
        >"$RELEASE_NESTED_CODE_LIST"
    then
        release_cleanup_nested_code_list
        release_fail "could not enumerate nested code: $release_nested_app_bundle"
    fi

    release_nested_verification_status=0
    while IFS= read -r -d '' release_nested_candidate; do
        (
            release_require_path_without_control_characters \
                "$release_nested_candidate" 'nested code candidate path'
            release_nested_description=$("$release_nested_file_path" -b "$release_nested_candidate") \
                || release_fail "could not inspect nested code candidate: $release_nested_candidate"
            case "$release_nested_description" in
                *Mach-O*) ;;
                *) exit 0 ;;
            esac
            [ -f "$release_nested_candidate" ] && [ ! -L "$release_nested_candidate" ] \
                && [ -x "$release_nested_candidate" ] \
                || release_fail "nested Mach-O candidate is unsafe: $release_nested_candidate"

            release_nested_identifier=
            case "$release_nested_candidate" in
                "$release_nested_sparkle/Sparkle")
                    release_nested_identifier=org.sparkle-project.Sparkle
                    ;;
                "$release_nested_sparkle/Updater.app/Contents/MacOS/Updater")
                    release_nested_identifier=org.sparkle-project.Sparkle.Updater
                    ;;
                "$release_nested_sparkle/XPCServices/Installer.xpc/Contents/MacOS/Installer")
                    release_nested_identifier=org.sparkle-project.InstallerLauncher
                    ;;
                "$release_nested_sparkle/XPCServices/Downloader.xpc/Contents/MacOS/Downloader")
                    release_nested_identifier=org.sparkle-project.DownloaderService
                    ;;
            esac

            "$release_nested_codesign_path" --verify --strict --verbose=4 "$release_nested_candidate" \
                || release_fail "nested code did not pass strict verification: $release_nested_candidate"
            release_verify_signature_metadata \
                "$release_nested_candidate" "$release_nested_identifier" yes \
                "$release_nested_codesign_path" "$release_nested_expected_identity" \
                "$release_nested_expected_team"
        ) || {
            release_nested_verification_status=$?
            break
        }
    done <"$RELEASE_NESTED_CODE_LIST"

    release_cleanup_nested_code_list \
        || release_fail 'could not remove nested code list'
    [ "$release_nested_verification_status" -eq 0 ] \
        || release_fail "nested code did not pass recursive verification: $release_nested_app_bundle"
}

release_verify_app_code_layout() {
    release_app_bundle=$1
    release_product_name=$2
    release_file_path=$3
    release_contents_dir=$release_app_bundle/Contents
    release_macos_dir=$release_contents_dir/MacOS
    release_main_executable=$release_macos_dir/$release_product_name

    [ -d "$release_contents_dir" ] \
        || release_fail "app Contents directory is missing: $release_contents_dir"
    [ ! -L "$release_contents_dir" ] \
        || release_fail "app Contents directory must not be a symlink: $release_contents_dir"
    [ -d "$release_macos_dir" ] \
        || release_fail "app MacOS directory is missing: $release_macos_dir"
    [ ! -L "$release_macos_dir" ] \
        || release_fail "app MacOS directory must not be a symlink: $release_macos_dir"
    [ -f "$release_main_executable" ] \
        || release_fail "main executable is missing or not a regular file: $release_main_executable"
    [ ! -L "$release_main_executable" ] \
        || release_fail "main executable must not be a symlink: $release_main_executable"
    [ -x "$release_main_executable" ] \
        || release_fail "main executable is not executable: $release_main_executable"

    release_macos_entry_count=0
    for release_macos_entry in "$release_macos_dir"/* "$release_macos_dir"/.*; do
        case "$release_macos_entry" in
            "$release_macos_dir/." | "$release_macos_dir/..") continue ;;
        esac
        [ -e "$release_macos_entry" ] || [ -L "$release_macos_entry" ] || continue
        [ "$release_macos_entry" = "$release_main_executable" ] \
            || release_fail "unexpected entry in Contents/MacOS: $release_macos_entry"
        release_macos_entry_count=$((release_macos_entry_count + 1))
    done
    [ "$release_macos_entry_count" -eq 1 ] \
        || release_fail "Contents/MacOS must contain exactly one main executable: $release_macos_dir"

    release_verify_frameworks_layout "$release_app_bundle"

    for release_nested_code_dir in \
        "$release_contents_dir/Frameworks" \
        "$release_contents_dir/PlugIns" \
        "$release_contents_dir/Plugins" \
        "$release_contents_dir/XPCServices" \
        "$release_contents_dir/Helpers" \
        "$release_contents_dir/Library/LoginItems" \
        "$release_contents_dir/Library/SystemExtensions" \
        "$release_contents_dir/Library/LaunchServices" \
        "$release_contents_dir/Library/QuickLook" \
        "$release_contents_dir/Library/Spotlight" \
        "$release_contents_dir/Library/Automator" \
        "$release_contents_dir/Library/Internet Plug-Ins"
    do
        case "$release_nested_code_dir" in
            */Frameworks)
                ;;
            */Helpers)
                release_verify_cli_helper_layout "$release_app_bundle"
                ;;
            *)
                release_require_empty_or_absent_directory "$release_nested_code_dir"
                ;;
        esac
    done

    release_nested_file_descriptions=$("$RELEASE_FIND_PATH" "$release_contents_dir" -type f \
        ! -path "$release_main_executable" \
        ! -path "$release_contents_dir/Helpers/quicktty" \
        ! -path "$release_contents_dir/Frameworks/Sparkle.framework/*" \
        -exec "$release_file_path" -b {} \;) \
        || release_fail "could not inspect app files for nested Mach-O code: $release_app_bundle"
    case "$release_nested_file_descriptions" in
        *Mach-O*) release_fail "unexpected nested Mach-O code: $release_app_bundle" ;;
    esac
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
        "$RELEASE_MKDIR_PATH" "$release_build_dir" || release_fail "could not create .build directory: $release_build_dir"
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
        "$RELEASE_MKDIR_PATH" "$release_output_dir" || release_fail "could not create release directory: $release_output_dir"
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
        "$release_output_dir/$RELEASE_NOTARY_RESULT_NAME" | \
        "$release_output_dir/$RELEASE_STAGE_NAME" | \
        "$release_output_dir/$RELEASE_APPCAST_DIRECTORY_NAME") ;;
        *) release_fail "refusing to remove non-generated release path: $release_candidate" ;;
    esac
}

release_assert_generated_path_absent() {
    release_output_dir=$1
    release_candidate=$2

    release_assert_generated_path "$release_output_dir" "$release_candidate"
    [ ! -e "$release_candidate" ] && [ ! -L "$release_candidate" ] \
        || release_fail "generated output path must be absent: $release_candidate"
}

release_remove_generated_directory() {
    release_output_dir=$1
    release_candidate=$2

    release_assert_generated_path "$release_output_dir" "$release_candidate"
    if [ -e "$release_candidate" ] || [ -L "$release_candidate" ]; then
        [ ! -L "$release_candidate" ] || release_fail "refusing to remove symlinked generated path: $release_candidate"
        [ -d "$release_candidate" ] || release_fail "generated directory path is not a directory: $release_candidate"
        printf 'cleanup: removing previous generated directory: %s\n' "$release_candidate"
        "$RELEASE_RM_PATH" -rf "$release_candidate"
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
        "$RELEASE_RM_PATH" -f "$release_candidate"
    fi
}
