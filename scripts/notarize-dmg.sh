#!/bin/sh
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
export PATH

set -eu

LC_ALL=C
export LC_ALL

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P) || {
    printf 'error: could not resolve script directory\n' >&2
    exit 1
}
repo_root=$(CDPATH= cd -P "$script_dir/.." && pwd -P) || {
    printf 'error: could not resolve repository root\n' >&2
    exit 1
}

# shellcheck source=release-helpers.sh
. "$script_dir/release-helpers.sh"
# shellcheck source=notarize-helpers.sh
. "$script_dir/notarize-helpers.sh"

DEFAULT_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
EXPECTED_DEVELOPMENT_TEAM=N8FS9YUZQA
EXPECTED_CODE_SIGN_IDENTITY='Developer ID Application: Dmitriy Lialiuev (N8FS9YUZQA)'

require_executable_path() {
    [ -x "$1" ] || release_fail "required tool is not executable: $1"
}

resolve_selected_xcode_tool() {
    selected_tool_name=$1
    selected_tool_path=$("$xcrun_path" --find "$selected_tool_name" 2>/dev/null) \
        || release_fail "$selected_tool_name was not found in the selected DEVELOPER_DIR"
    [ -x "$selected_tool_path" ] \
        || release_fail "$selected_tool_name is not executable in the selected DEVELOPER_DIR: $selected_tool_path"
    case "$selected_tool_path" in
        "$DEVELOPER_DIR"/*) ;;
        *) release_fail "$selected_tool_name resolved outside the selected DEVELOPER_DIR: $selected_tool_path" ;;
    esac
    printf '%s\n' "$selected_tool_path"
}

signature_has_exact_line() {
    notarize_signature_data=$1
    notarize_expected_line=$2

    while IFS= read -r notarize_signature_line || [ -n "$notarize_signature_line" ]; do
        [ "$notarize_signature_line" = "$notarize_expected_line" ] && return 0
    done <<EOF
$notarize_signature_data
EOF

    return 1
}

signature_has_prefix() {
    notarize_signature_data=$1
    notarize_expected_prefix=$2

    while IFS= read -r notarize_signature_line || [ -n "$notarize_signature_line" ]; do
        case "$notarize_signature_line" in
            "$notarize_expected_prefix"*) return 0 ;;
        esac
    done <<EOF
$notarize_signature_data
EOF

    return 1
}

verify_dmg_signature_metadata() {
    notarize_signature_data=$("$codesign_path" -d -vvv "$DMG" 2>&1) \
        || release_fail "could not display code-signature metadata: $DMG"

    signature_has_exact_line "$notarize_signature_data" "Authority=$EXPECTED_CODE_SIGN_IDENTITY" \
        || release_fail "signature authority does not match the expected Developer ID identity: $DMG"
    signature_has_exact_line "$notarize_signature_data" "TeamIdentifier=$EXPECTED_DEVELOPMENT_TEAM" \
        || release_fail "signature team does not match the expected Developer ID team: $DMG"
    signature_has_prefix "$notarize_signature_data" 'Timestamp=' \
        || release_fail "signature has no secure timestamp: $DMG"
}

assert_result_path() {
    if [ -e "$notary_result_path" ] || [ -L "$notary_result_path" ]; then
        [ -f "$notary_result_path" ] \
            || release_fail "notarization result is not a regular file: $notary_result_path"
        [ ! -L "$notary_result_path" ] \
            || release_fail "notarization result must not be a symlink: $notary_result_path"
    fi
}

notary_result_tmp=

cleanup_notary_result_tmp() {
    cleanup_status=$?
    trap - 0 HUP INT TERM

    if [ -n "$notary_result_tmp" ] && [ -f "$notary_result_tmp" ]; then
        "$rm_path" -f "$notary_result_tmp" || {
            printf 'error: could not remove temporary notarization result: %s\n' "$notary_result_tmp" >&2
        }
    fi

    exit "$cleanup_status"
}

release_require_no_arguments "$@"
release_reject_secret_environment

if [ "${NOTARY_PROFILE+x}" != x ]; then
    NOTARY_PROFILE=$NOTARY_PROFILE_DEFAULT
fi
notarize_validate_profile "$NOTARY_PROFILE"
[ -n "${DMG:-}" ] || release_fail 'DMG must be set'

[ -e "$repo_root/.git" ] || release_fail "not a Git repository: $repo_root"
expected_dmg_path=$repo_root/.build/Release/$RELEASE_DMG_NAME
notarize_validate_dmg_path "$DMG" "$expected_dmg_path"
release_dir=${expected_dmg_path%/*}
notary_result_path=$release_dir/$NOTARY_RESULT_NAME
assert_result_path

DEVELOPER_DIR=${DEVELOPER_DIR:-$DEFAULT_DEVELOPER_DIR}
[ -d "$DEVELOPER_DIR" ] || release_fail "DEVELOPER_DIR is not an existing directory: $DEVELOPER_DIR"
developer_dir_canonical=$(CDPATH= cd -P "$DEVELOPER_DIR" && pwd -P) \
    || release_fail "could not resolve DEVELOPER_DIR: $DEVELOPER_DIR"
DEVELOPER_DIR=$developer_dir_canonical
export DEVELOPER_DIR

codesign_path=/usr/bin/codesign
spctl_path=/usr/sbin/spctl
xcrun_path=/usr/bin/xcrun
plutil_path=/usr/bin/plutil
shasum_path=/usr/bin/shasum
stat_path=/usr/bin/stat
mktemp_path=/usr/bin/mktemp
mv_path=/bin/mv
rm_path=/bin/rm
git_path=/usr/bin/git

for required_tool_path in \
    "$codesign_path" \
    "$spctl_path" \
    "$xcrun_path" \
    "$plutil_path" \
    "$shasum_path" \
    "$stat_path" \
    "$mktemp_path" \
    "$mv_path" \
    "$rm_path" \
    "$git_path"
do
    require_executable_path "$required_tool_path"
done

notarytool_path=$(resolve_selected_xcode_tool notarytool)
stapler_path=$(resolve_selected_xcode_tool stapler)
[ -n "$notarytool_path" ] && [ -n "$stapler_path" ] \
    || release_fail 'selected Xcode notarization tools could not be resolved'

source_tree_state=$(release_source_tree_state "$repo_root" "$git_path") \
    || release_fail 'could not determine source tree state'
[ "$source_tree_state" = clean ] \
    || release_fail 'source tree is dirty; refusing to notarize a mismatched artifact'

"$codesign_path" --verify --strict --verbose=4 "$DMG" \
    || release_fail "DMG did not pass strict code-signature verification: $DMG"
verify_dmg_signature_metadata

dmg_size=$("$stat_path" -f '%z' "$DMG") \
    || release_fail "could not determine DMG size: $DMG"
dmg_hash_output=$("$shasum_path" -a 256 "$DMG") \
    || release_fail "could not calculate DMG SHA-256: $DMG"
dmg_hash=${dmg_hash_output%% *}
case "$dmg_hash" in
    ????????????????????????????????????????????????????????????????????????)
        case "$dmg_hash" in
            *[!0-9A-Fa-f]*) release_fail "could not calculate DMG SHA-256: $DMG" ;;
        esac
        ;;
    *) release_fail "could not calculate DMG SHA-256: $DMG" ;;
esac

printf 'DMG: %s\n' "$DMG"
printf 'Size: %s bytes\n' "$dmg_size"
printf 'SHA-256: %s\n' "$dmg_hash"
printf '%s\n' 'Stage: submitting DMG to Apple notary service and waiting for completion.'

notary_result_tmp=$("$mktemp_path" "$release_dir/.GhostTerm-notary-result.XXXXXX") \
    || release_fail "could not create temporary notarization result in: $release_dir"
case "$notary_result_tmp" in
    "$release_dir"/.GhostTerm-notary-result.*) ;;
    *) release_fail "temporary notarization result has an unexpected path: $notary_result_tmp" ;;
esac
[ -f "$notary_result_tmp" ] && [ ! -L "$notary_result_tmp" ] \
    || release_fail "temporary notarization result is unsafe: $notary_result_tmp"
trap cleanup_notary_result_tmp 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

notary_submit_status=0
if "$xcrun_path" notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json >"$notary_result_tmp"
then
    :
else
    notary_submit_status=$?
fi

[ -s "$notary_result_tmp" ] \
    || release_fail "notarytool submit produced no JSON result: $notary_result_tmp"
"$mv_path" -f "$notary_result_tmp" "$notary_result_path" \
    || release_fail "could not save notarization result: $notary_result_path"
notary_result_tmp=

notarize_parse_result "$plutil_path" "$notary_result_path"
if [ "$NOTARIZE_STATUS" != Accepted ]; then
    printf 'error: notarization status is %s; result saved at %s\n' \
        "$NOTARIZE_STATUS" "$notary_result_path" >&2
    printf 'xcrun notarytool log %s --keychain-profile %s\n' \
        "$NOTARIZE_SUBMISSION_ID" "$NOTARY_PROFILE" >&2
    exit 1
fi
[ "$notary_submit_status" -eq 0 ] \
    || release_fail "notarytool submit failed after reporting Accepted; result saved at: $notary_result_path"

printf '%s\n' 'Stage: stapling notarization ticket to DMG.'
"$xcrun_path" stapler staple "$DMG" \
    || release_fail "could not staple notarization ticket: $DMG"
printf '%s\n' 'Stage: validating stapled notarization ticket.'
"$xcrun_path" stapler validate "$DMG" \
    || release_fail "stapled notarization ticket is invalid: $DMG"
"$codesign_path" --verify --strict --verbose=4 "$DMG" \
    || release_fail "stapled DMG did not pass strict code-signature verification: $DMG"
"$spctl_path" --assess --type open --context context:primary-signature --verbose=4 "$DMG" \
    || release_fail "Gatekeeper assessment failed: $DMG"

trap - 0 HUP INT TERM
printf 'Notarized DMG: %s\n' "$DMG"
printf 'Submission ID: %s\n' "$NOTARIZE_SUBMISSION_ID"
printf 'SHA-256: %s\n' "$dmg_hash"
printf 'Evidence: %s\n' "$notary_result_path"
