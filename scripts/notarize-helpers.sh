#!/bin/sh

NOTARY_PROFILE_DEFAULT=quicktty-notary
NOTARIZE_DEFAULT_DMG=.build/Release/$RELEASE_DMG_NAME

notarize_apply_defaults() {
    if [ "${NOTARY_PROFILE+x}" != x ]; then
        NOTARY_PROFILE=$NOTARY_PROFILE_DEFAULT
    fi
    if [ "${DMG+x}" != x ]; then
        DMG=$NOTARIZE_DEFAULT_DMG
    fi
}

notarize_validate_profile() {
    notarize_profile=$1

    [ -n "$notarize_profile" ] || release_fail 'NOTARY_PROFILE must not be empty'
    case "$notarize_profile" in
        *[!A-Za-z0-9._-]*)
            release_fail 'NOTARY_PROFILE contains unsupported characters'
            ;;
    esac
}

notarize_resolve_dmg_path() {
    notarize_dmg_input=$1
    notarize_repo_root=$2
    notarize_expected_dmg_path=$3

    [ -n "$notarize_dmg_input" ] || release_fail 'DMG must be set'
    [ -d "$notarize_repo_root" ] || release_fail "repository root is not a directory: $notarize_repo_root"
    [ ! -L "$notarize_repo_root" ] || release_fail "repository root must not be a symlink: $notarize_repo_root"
    notarize_repo_root_canonical=$(CDPATH= cd -P "$notarize_repo_root" && pwd -P) \
        || release_fail "could not resolve repository root: $notarize_repo_root"
    [ "$notarize_repo_root_canonical" = "$notarize_repo_root" ] \
        || release_fail "repository root is not canonical: $notarize_repo_root"

    case "/$notarize_dmg_input/" in
        */../*) release_fail 'DMG must not contain .. path components' ;;
    esac
    case "$notarize_dmg_input" in
        /*) notarize_dmg_path=$notarize_dmg_input ;;
        *) notarize_dmg_path=$notarize_repo_root/$notarize_dmg_input ;;
    esac

    notarize_dmg_parent=${notarize_dmg_path%/*}
    notarize_dmg_name=${notarize_dmg_path##*/}
    [ -n "$notarize_dmg_parent" ] || notarize_dmg_parent=/
    [ -n "$notarize_dmg_name" ] || release_fail 'DMG must name a regular file'

    [ -f "$notarize_dmg_path" ] || release_fail "DMG is not an existing regular file: $notarize_dmg_path"
    [ ! -L "$notarize_dmg_path" ] || release_fail "DMG must not be a symlink: $notarize_dmg_path"
    [ -d "$notarize_dmg_parent" ] || release_fail "DMG parent is not a directory: $notarize_dmg_parent"

    notarize_dmg_parent_canonical=$(CDPATH= cd -P "$notarize_dmg_parent" && pwd -P) \
        || release_fail "could not resolve DMG parent: $notarize_dmg_parent"
    notarize_dmg_canonical=$notarize_dmg_parent_canonical/$notarize_dmg_name

    [ "$notarize_dmg_path" = "$notarize_dmg_canonical" ] \
        || release_fail "DMG path is not canonical: $notarize_dmg_path"
    [ "$notarize_dmg_canonical" = "$notarize_expected_dmg_path" ] \
        || release_fail "DMG must be the expected release artifact: $notarize_expected_dmg_path"
    printf '%s\n' "$notarize_dmg_canonical"
}

notarize_is_valid_sha256() {
    notarize_sha256=$1

    [ "${#notarize_sha256}" -eq 64 ] || return 1
    case "$notarize_sha256" in
        *[!0-9A-Fa-f]*) return 1 ;;
    esac
}

notarize_validate_submission_id() {
    notarize_submission_id=$1

    notarize_uuid_part_1=${notarize_submission_id%%-*}
    notarize_uuid_remaining=${notarize_submission_id#*-}
    [ "$notarize_uuid_remaining" != "$notarize_submission_id" ] \
        || release_fail 'notarization result has an invalid submission id'

    notarize_uuid_part_2=${notarize_uuid_remaining%%-*}
    notarize_uuid_remaining=${notarize_uuid_remaining#*-}
    [ "$notarize_uuid_remaining" != "$notarize_uuid_part_2" ] \
        || release_fail 'notarization result has an invalid submission id'

    notarize_uuid_part_3=${notarize_uuid_remaining%%-*}
    notarize_uuid_remaining=${notarize_uuid_remaining#*-}
    [ "$notarize_uuid_remaining" != "$notarize_uuid_part_3" ] \
        || release_fail 'notarization result has an invalid submission id'

    notarize_uuid_part_4=${notarize_uuid_remaining%%-*}
    notarize_uuid_remaining=${notarize_uuid_remaining#*-}
    [ "$notarize_uuid_remaining" != "$notarize_uuid_part_4" ] \
        || release_fail 'notarization result has an invalid submission id'

    notarize_uuid_part_5=$notarize_uuid_remaining

    [ "${#notarize_uuid_part_1}" -eq 8 ] \
        && [ "${#notarize_uuid_part_2}" -eq 4 ] \
        && [ "${#notarize_uuid_part_3}" -eq 4 ] \
        && [ "${#notarize_uuid_part_4}" -eq 4 ] \
        && [ "${#notarize_uuid_part_5}" -eq 12 ] \
        || release_fail 'notarization result has an invalid submission id'

    case "$notarize_uuid_part_1$notarize_uuid_part_2$notarize_uuid_part_3$notarize_uuid_part_4$notarize_uuid_part_5" in
        *[!0-9A-Fa-f]*) release_fail 'notarization result has an invalid submission id' ;;
    esac
}

notarize_parse_result() {
    notarize_plutil_path=$1
    notarize_result_path=$2

    [ -f "$notarize_result_path" ] \
        || release_fail "notarization result is not a regular file: $notarize_result_path"
    [ ! -L "$notarize_result_path" ] \
        || release_fail "notarization result must not be a symlink: $notarize_result_path"

    NOTARIZE_STATUS=$("$notarize_plutil_path" -extract status raw -o - "$notarize_result_path" 2>/dev/null) \
        || release_fail "notarization result has no status: $notarize_result_path"
    NOTARIZE_SUBMISSION_ID=$("$notarize_plutil_path" -extract id raw -o - "$notarize_result_path" 2>/dev/null) \
        || release_fail "notarization result has no submission id: $notarize_result_path"

    [ -n "$NOTARIZE_STATUS" ] || release_fail "notarization result has an empty status: $notarize_result_path"
    notarize_validate_submission_id "$NOTARIZE_SUBMISSION_ID"
}
