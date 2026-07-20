#!/bin/sh
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
export PATH

set -eu

LC_ALL=C
export LC_ALL

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

assert_equals() {
    [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

assert_missing() {
    [ ! -e "$1" ] && [ ! -L "$1" ] || fail "path should be absent: $1"
}

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        fail "expected command to fail: $*"
    fi
}

run_notarize_negative() {
    env -i \
        PATH="$PATH" \
        TMPDIR="${TMPDIR:-/tmp}" \
        DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}" \
        CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}" \
        DMG="${DMG:-}" \
        NOTARY_PROFILE="${NOTARY_PROFILE:-}" \
        /bin/sh "$notarize_script" "$@"
}

expect_notarize_failure() {
    expected_message=$1
    shift

    if notarize_output=$(run_notarize_negative "$@" 2>&1); then
        fail "expected notarization script to fail: $*"
    fi
    case "$notarize_output" in
        *"$expected_message"*) ;;
        *) fail "unexpected notarization failure: $notarize_output" ;;
    esac
}

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P) || fail 'could not resolve test directory'
repo_root=$(CDPATH= cd -P "$script_dir/../.." && pwd -P) || fail 'could not resolve repository root'
release_helpers=$repo_root/scripts/release-helpers.sh
notarize_helpers=$repo_root/scripts/notarize-helpers.sh
notarize_script=$repo_root/scripts/notarize-dmg.sh
makefile=$repo_root/Makefile
test_development_team=ABCDE12345
test_code_sign_identity="Developer ID Application: Contract Test ($test_development_team)"

[ -f "$release_helpers" ] || fail "release helpers are missing: $release_helpers"
[ -f "$notarize_helpers" ] || fail "notarization helpers are missing: $notarize_helpers"
[ -f "$notarize_script" ] || fail "notarization script is missing: $notarize_script"
[ -f "$makefile" ] || fail "Makefile is missing: $makefile"

for shell_script in "$repo_root"/scripts/*.sh "$repo_root"/scripts/tests/*.sh; do
    [ -f "$shell_script" ] || continue
    sh -n "$shell_script"
done
grep -F -x 'PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin' "$notarize_script" >/dev/null \
    || fail 'notarization script does not set the trusted PATH'
grep -F -x '"$spctl_path" --assess --type open --context context:primary-signature --verbose=4 "$DMG" \' \
    "$notarize_script" >/dev/null \
    || fail 'notarization script does not use the required Gatekeeper assessment context'
grep -F -x 'xcrun_path=/usr/bin/xcrun' "$notarize_script" >/dev/null \
    || fail 'notarization script does not pin xcrun to /usr/bin/xcrun'
grep -F -x '    selected_tool_path=$("$xcrun_path" --find "$selected_tool_name" 2>/dev/null) \' \
    "$notarize_script" >/dev/null \
    || fail 'notarization script does not resolve selected Xcode tools with xcrun'
grep -F -x 'xcodebuild_path=$(resolve_selected_xcode_tool xcodebuild)' "$notarize_script" >/dev/null \
    || fail 'notarization script does not resolve xcodebuild from the selected developer directory'
grep -F -x '[ "$xcodebuild_path" = "$DEVELOPER_DIR/usr/bin/xcodebuild" ] \' \
    "$notarize_script" >/dev/null \
    || fail 'notarization script does not require full Xcode'
grep -F -x 'release_validate_team "${DEVELOPMENT_TEAM:-}"' "$notarize_script" >/dev/null \
    || fail 'notarization script does not validate DEVELOPMENT_TEAM'
grep -F -x 'release_validate_identity "${CODE_SIGN_IDENTITY:-}"' "$notarize_script" >/dev/null \
    || fail 'notarization script does not validate CODE_SIGN_IDENTITY'
grep -F -x '    signature_has_exact_line "$notarize_signature_data" "Authority=$CODE_SIGN_IDENTITY" \' \
    "$notarize_script" >/dev/null \
    || fail 'notarization script does not check the supplied code-signing identity'
grep -F -x '    signature_has_exact_line "$notarize_signature_data" "TeamIdentifier=$DEVELOPMENT_TEAM" \' \
    "$notarize_script" >/dev/null \
    || fail 'notarization script does not check the supplied development team'
if grep -F -e EXPECTED_DEVELOPMENT_TEAM -e EXPECTED_CODE_SIGN_IDENTITY "$notarize_script" >/dev/null; then
    fail 'notarization script hardcodes signing metadata'
fi
grep -F -x 'notarize: export DEVELOPMENT_TEAM := $(DEVELOPMENT_TEAM)' "$makefile" >/dev/null \
    || fail 'notarize target does not export DEVELOPMENT_TEAM'
grep -F -x 'notarize: export CODE_SIGN_IDENTITY := $(CODE_SIGN_IDENTITY)' "$makefile" >/dev/null \
    || fail 'notarize target does not export CODE_SIGN_IDENTITY'
grep -F -x 'signed-alpha: export DEVELOPMENT_TEAM := $(DEVELOPMENT_TEAM)' "$makefile" >/dev/null \
    || fail 'signed-alpha target does not export DEVELOPMENT_TEAM'
grep -F -x 'signed-alpha: export CODE_SIGN_IDENTITY := $(CODE_SIGN_IDENTITY)' "$makefile" >/dev/null \
    || fail 'signed-alpha target does not export CODE_SIGN_IDENTITY'
gatekeeper_assessment_line=$(grep -n -F -x \
    '"$spctl_path" --assess --type open --context context:primary-signature --verbose=4 "$DMG" \' \
    "$notarize_script" | /usr/bin/cut -d: -f1)
final_size_calculation_line=$(grep -n -F -x \
    'dmg_size=$("$stat_path" -f '\''%z'\'' "$DMG") \' \
    "$notarize_script" | /usr/bin/cut -d: -f1)
final_hash_calculation_line=$(grep -n -F -x \
    'dmg_hash_output=$("$shasum_path" -a 256 "$DMG") \' \
    "$notarize_script" | /usr/bin/cut -d: -f1)
final_size_report_line=$(grep -n -F -x \
    'printf '\''Size: %s bytes\n'\'' "$dmg_size"' \
    "$notarize_script" | /usr/bin/cut -d: -f1)
final_hash_report_line=$(grep -n -F -x \
    'printf '\''SHA-256: %s\n'\'' "$dmg_hash"' \
    "$notarize_script" | /usr/bin/cut -d: -f1)
[ "$final_size_calculation_line" -gt "$gatekeeper_assessment_line" ] \
    || fail 'notarization script does not calculate the final DMG size after Gatekeeper assessment'
[ "$final_hash_calculation_line" -gt "$gatekeeper_assessment_line" ] \
    || fail 'notarization script does not calculate the final DMG SHA-256 after Gatekeeper assessment'
[ "$final_size_report_line" -gt "$final_size_calculation_line" ] \
    || fail 'notarization script does not report the final DMG size after calculating it'
[ "$final_hash_report_line" -gt "$final_hash_calculation_line" ] \
    || fail 'notarization script does not report the final DMG SHA-256 after calculating it'

DMG=
NOTARY_PROFILE=ghostterm-notary
DEVELOPMENT_TEAM=
CODE_SIGN_IDENTITY=
expect_notarize_failure 'error: this script accepts no options or positional arguments' unexpected-option
expect_notarize_failure 'error: DEVELOPMENT_TEAM must be set'
DEVELOPMENT_TEAM=$test_development_team
expect_notarize_failure 'error: CODE_SIGN_IDENTITY must be set'
CODE_SIGN_IDENTITY=$test_code_sign_identity
expect_notarize_failure 'error: DMG must be set'
if default_profile_output=$(env -i \
    PATH="$PATH" \
    TMPDIR="${TMPDIR:-/tmp}" \
    DEVELOPMENT_TEAM="$test_development_team" \
    CODE_SIGN_IDENTITY="$test_code_sign_identity" \
    DMG= \
    /bin/sh "$notarize_script" 2>&1)
then
    fail 'notarization script accepted a missing DMG with the default profile'
fi
case "$default_profile_output" in
    *'error: DMG must be set'*) ;;
    *) fail "unexpected default profile failure: $default_profile_output" ;;
esac
NOTARY_PROFILE=
expect_notarize_failure 'error: NOTARY_PROFILE must not be empty'
NOTARY_PROFILE='invalid profile'
expect_notarize_failure 'error: NOTARY_PROFILE contains unsupported characters'
NOTARY_PROFILE=ghostterm-notary
if secret_output=$(env -i \
    PATH="$PATH" \
    TMPDIR="${TMPDIR:-/tmp}" \
    DMG= \
    APPLE_ID=unused \
    /bin/sh "$notarize_script" 2>&1)
then
    fail 'notarization script accepted a secret environment variable'
fi
case "$secret_output" in
    *'error: secret environment variable is not accepted: APPLE_ID'*) ;;
    *) fail "unexpected secret environment failure: $secret_output" ;;
esac

. "$release_helpers"
. "$notarize_helpers"

notarize_validate_profile ghostterm-notary
release_validate_team "$test_development_team"
release_validate_identity "$test_code_sign_identity"
expect_failure /bin/sh -c '. "$1"; . "$2"; notarize_validate_profile "bad profile"' sh \
    "$release_helpers" "$notarize_helpers"

TMPDIR=${TMPDIR:-/tmp}
tmp_base=$(CDPATH= cd -P "$TMPDIR" && pwd -P) || fail "could not resolve temporary directory base: $TMPDIR"
[ -n "$tmp_base" ] && [ "$tmp_base" != / ] || fail 'temporary directory base must not be empty or /'
tmp_root=

cleanup() {
    cleanup_status=$?
    trap - 0 HUP INT TERM

    if [ -n "$tmp_root" ] && [ -d "$tmp_root" ]; then
        case "$tmp_root" in
            "$tmp_base"/ghostterm-notarize-test.*) /bin/rm -rf "$tmp_root" ;;
            *) printf 'error: refusing to remove unexpected temporary path: %s\n' "$tmp_root" >&2 ;;
        esac
    fi

    exit "$cleanup_status"
}

trap cleanup 0 HUP INT TERM
tmp_root=$(/usr/bin/mktemp -d "$tmp_base/ghostterm-notarize-test.XXXXXX") \
    || fail 'could not create temporary directory'
case "$tmp_root" in
    "$tmp_base"/ghostterm-notarize-test.*) ;;
    *) fail "temporary directory has an unexpected path: $tmp_root" ;;
esac

fixture_repo=$tmp_root/repository
fixture_release_dir=$fixture_repo/.build/Release
fixture_dmg=$fixture_release_dir/$RELEASE_DMG_NAME
/bin/mkdir -p "$fixture_release_dir"
printf 'fixture DMG\n' >"$fixture_dmg"
notarize_validate_dmg_path "$fixture_dmg" "$fixture_dmg"
expect_failure /bin/sh -c '. "$1"; . "$2"; notarize_validate_dmg_path "$3" "$4"' sh \
    "$release_helpers" "$notarize_helpers" "$fixture_release_dir/../Release/$RELEASE_DMG_NAME" "$fixture_dmg"

wrong_dmg=$tmp_root/wrong.dmg
printf 'wrong DMG\n' >"$wrong_dmg"
DMG=$wrong_dmg
NOTARY_PROFILE=ghostterm-notary
expect_notarize_failure 'error: DMG must be the expected release artifact'

symlink_dmg=$tmp_root/symlink.dmg
/bin/ln -s "$wrong_dmg" "$symlink_dmg"
DMG=$symlink_dmg
expect_notarize_failure 'error: DMG must not be a symlink'

DMG=relative.dmg
expect_notarize_failure 'error: DMG must be an absolute canonical path'

accepted_result=$tmp_root/accepted.json
invalid_result=$tmp_root/invalid.json
missing_result=$tmp_root/missing.json
printf '%s\n' '{"id":"01234567-89ab-cdef-0123-456789abcdef","status":"Accepted"}' >"$accepted_result"
printf '%s\n' '{"id":"01234567-89ab-cdef-0123-456789abcdef","status":"Invalid"}' >"$invalid_result"
printf '%s\n' '{"status":"Accepted"}' >"$missing_result"

notarize_parse_result /usr/bin/plutil "$accepted_result"
assert_equals "$NOTARIZE_STATUS" Accepted
assert_equals "$NOTARIZE_SUBMISSION_ID" 01234567-89ab-cdef-0123-456789abcdef
notarize_parse_result /usr/bin/plutil "$invalid_result"
assert_equals "$NOTARIZE_STATUS" Invalid
expect_failure /bin/sh -c '. "$1"; . "$2"; notarize_parse_result /usr/bin/plutil "$3"' sh \
    "$release_helpers" "$notarize_helpers" "$missing_result"

malicious_bin=$tmp_root/malicious-bin
malicious_marker=$tmp_root/malicious-command-ran
malicious_output=$tmp_root/malicious-command-output
/bin/mkdir "$malicious_bin"
printf '#!/bin/sh\n: >"$GHOSTTERM_MALICIOUS_MARKER"\nexit 99\n' >"$malicious_bin/dirname"
/bin/chmod +x "$malicious_bin/dirname"
if PATH="$malicious_bin:/usr/bin:/bin" \
    GHOSTTERM_MALICIOUS_MARKER="$malicious_marker" \
    DEVELOPMENT_TEAM= \
    CODE_SIGN_IDENTITY= \
    DMG= \
    NOTARY_PROFILE= \
    /bin/sh "$notarize_script" unexpected-option >"$malicious_output" 2>&1
then
    fail 'notarization script accepted an unexpected argument with a malicious inherited PATH'
fi
malicious_output_contents=
IFS= read -r malicious_output_contents <"$malicious_output" || :
case "$malicious_output_contents" in
    *'error: this script accepts no options or positional arguments'*) ;;
    *) fail 'notarization script did not reach argument validation with a malicious inherited PATH' ;;
esac
assert_missing "$malicious_marker"

printf 'Notarization DMG contract tests passed.\n'
