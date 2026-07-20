#!/bin/sh

NOTARY_PROFILE_DEFAULT=ghostterm-notary
NOTARY_RESULT_NAME=$RELEASE_DMG_NAME.notary-result.json

notarize_validate_profile() {
    notarize_profile=$1

    [ -n "$notarize_profile" ] || release_fail 'NOTARY_PROFILE must not be empty'
    case "$notarize_profile" in
        *[!A-Za-z0-9._-]*)
            release_fail 'NOTARY_PROFILE contains unsupported characters'
            ;;
    esac
}

notarize_validate_dmg_path() {
    notarize_dmg_path=$1
    notarize_expected_dmg_path=$2

    [ -n "$notarize_dmg_path" ] || release_fail 'DMG must be set'
    case "$notarize_dmg_path" in
        /*) ;;
        *) release_fail 'DMG must be an absolute canonical path' ;;
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
