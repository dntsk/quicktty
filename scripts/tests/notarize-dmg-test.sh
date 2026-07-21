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

assert_make_capture() {
    make_capture_path=$1
    make_capture_team=$2
    make_capture_identity=$3
    make_capture_dmg=$4
    make_capture_profile=$5
    make_capture_developer_dir=$6
    make_capture_release_label=$7

    grep -F -x "DEVELOPMENT_TEAM=$make_capture_team" "$make_capture_path" >/dev/null \
        || fail "make did not deliver DEVELOPMENT_TEAM to the recipe: $make_capture_path"
    grep -F -x "CODE_SIGN_IDENTITY=$make_capture_identity" "$make_capture_path" >/dev/null \
        || fail "make did not deliver CODE_SIGN_IDENTITY to the recipe: $make_capture_path"
    grep -F -x "DMG=$make_capture_dmg" "$make_capture_path" >/dev/null \
        || fail "make did not deliver DMG to the recipe: $make_capture_path"
    grep -F -x "NOTARY_PROFILE=$make_capture_profile" "$make_capture_path" >/dev/null \
        || fail "make did not deliver NOTARY_PROFILE to the recipe: $make_capture_path"
    grep -F -x "DEVELOPER_DIR=$make_capture_developer_dir" "$make_capture_path" >/dev/null \
        || fail "make did not deliver DEVELOPER_DIR to the recipe: $make_capture_path"
    grep -F -x "RELEASE_LABEL=$make_capture_release_label" "$make_capture_path" >/dev/null \
        || fail "make did not deliver RELEASE_LABEL to the recipe: $make_capture_path"
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
default_developer_dir=/Applications/Xcode.app/Contents/Developer
test_developer_dir=$default_developer_dir
test_release_label=0.1.0-alpha.1

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
grep -F -x 'notarize_apply_defaults' "$notarize_script" >/dev/null \
    || fail 'notarization script does not apply its own defaults'
grep -F -x 'DMG=$(notarize_resolve_dmg_path "$DMG" "$repo_root" "$expected_dmg_path")' "$notarize_script" >/dev/null \
    || fail 'notarization script does not resolve DMG against the repository root'
if grep -E '^(release|notarize|signed-alpha):[[:space:]]+export[[:space:]]' "$makefile" >/dev/null; then
    fail 'release targets must not use target-specific exported variables'
fi
if grep -E '^[[:space:]]+.*(DEVELOPMENT_TEAM|CODE_SIGN_IDENTITY|DMG|NOTARY_PROFILE)' "$makefile" >/dev/null; then
    fail 'release recipes must not expand signing or notarization inputs'
fi
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
unset DMG NOTARY_PROFILE
notarize_apply_defaults
assert_equals "$DMG" ".build/Release/$RELEASE_DMG_NAME"
assert_equals "$NOTARY_PROFILE" ghostterm-notary
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
assert_equals "$(notarize_resolve_dmg_path ".build/Release/$RELEASE_DMG_NAME" "$fixture_repo" "$fixture_dmg")" "$fixture_dmg"
assert_equals "$(notarize_resolve_dmg_path "$fixture_dmg" "$fixture_repo" "$fixture_dmg")" "$fixture_dmg"
expect_failure /bin/sh -c '. "$1"; . "$2"; notarize_resolve_dmg_path "$3" "$4" "$5"' sh \
    "$release_helpers" "$notarize_helpers" ".build/Release/../Release/$RELEASE_DMG_NAME" "$fixture_repo" "$fixture_dmg"
fixture_linked_release=$fixture_repo/.build/linked-Release
/bin/ln -s "$fixture_release_dir" "$fixture_linked_release"
expect_failure /bin/sh -c '. "$1"; . "$2"; notarize_resolve_dmg_path "$3" "$4" "$5"' sh \
    "$release_helpers" "$notarize_helpers" ".build/linked-Release/$RELEASE_DMG_NAME" "$fixture_repo" "$fixture_dmg"

wrong_dmg=$tmp_root/wrong.dmg
printf 'wrong DMG\n' >"$wrong_dmg"
expect_failure /bin/sh -c '. "$1"; . "$2"; notarize_resolve_dmg_path "$3" "$4" "$5"' sh \
    "$release_helpers" "$notarize_helpers" "$wrong_dmg" "$fixture_repo" "$fixture_dmg"
DMG=$wrong_dmg
NOTARY_PROFILE=ghostterm-notary
expect_notarize_failure 'error: DMG must be the expected release artifact'

symlink_dmg=$tmp_root/symlink.dmg
/bin/ln -s "$wrong_dmg" "$symlink_dmg"
DMG=$symlink_dmg
expect_notarize_failure 'error: DMG must not be a symlink'

DMG=.build/Release/../Release/$RELEASE_DMG_NAME
expect_notarize_failure 'error: DMG must not contain .. path components'

make_path=/usr/bin/make
[ -x "$make_path" ] || fail "make is not executable: $make_path"
grep -F -x 'ifneq ($(filter release notarize signed-alpha,$(MAKECMDGOALS)),)' "$makefile" >/dev/null \
    || fail 'Makefile does not scope command-line variable rejection to release goals'
for release_make_variable in \
    DEVELOPMENT_TEAM \
    CODE_SIGN_IDENTITY \
    DMG \
    NOTARY_PROFILE \
    DEVELOPER_DIR \
    RELEASE_LABEL
do
    grep -F -x "ifeq (\$(origin $release_make_variable),command line)" "$makefile" >/dev/null \
        || fail "Makefile does not reject command-line $release_make_variable for release goals"
done

make_fixture=$tmp_root/make-fixture
make_fixture_scripts=$make_fixture/scripts
make_notarize_capture=$tmp_root/make-notarize-capture
make_release_capture=$tmp_root/make-release-capture
make_signed_release_capture=$tmp_root/make-signed-release-capture
make_signed_notarize_capture=$tmp_root/make-signed-notarize-capture
make_default_release_capture=$tmp_root/make-default-release-capture
make_command_line_release_capture=$tmp_root/make-command-line-release-capture
make_command_line_notarize_capture=$tmp_root/make-command-line-notarize-capture
make_command_line_output=$tmp_root/make-command-line-output
/bin/mkdir -p "$make_fixture_scripts"
/bin/cp "$makefile" "$make_fixture/Makefile"
printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    ': "${GHOSTTERM_NOTARIZE_CAPTURE:?}"' \
    'printf "DEVELOPMENT_TEAM=%s\\nCODE_SIGN_IDENTITY=%s\\nDMG=%s\\nNOTARY_PROFILE=%s\\nDEVELOPER_DIR=%s\\nRELEASE_LABEL=%s\\n" "${DEVELOPMENT_TEAM-}" "${CODE_SIGN_IDENTITY-}" "${DMG-}" "${NOTARY_PROFILE-}" "${DEVELOPER_DIR-}" "${RELEASE_LABEL-}" >"$GHOSTTERM_NOTARIZE_CAPTURE"' \
    >"$make_fixture_scripts/notarize-dmg.sh"
printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    ': "${GHOSTTERM_RELEASE_CAPTURE:?}"' \
    'printf "DEVELOPMENT_TEAM=%s\\nCODE_SIGN_IDENTITY=%s\\nDMG=%s\\nNOTARY_PROFILE=%s\\nDEVELOPER_DIR=%s\\nRELEASE_LABEL=%s\\n" "${DEVELOPMENT_TEAM-}" "${CODE_SIGN_IDENTITY-}" "${DMG-}" "${NOTARY_PROFILE-}" "${DEVELOPER_DIR-}" "${RELEASE_LABEL-}" >"$GHOSTTERM_RELEASE_CAPTURE"' \
    >"$make_fixture_scripts/build-release.sh"
/bin/chmod +x "$make_fixture_scripts/notarize-dmg.sh" "$make_fixture_scripts/build-release.sh"

make_expansion_marker=$tmp_root/make-expansion-marker
literal_make_value='$(shell /usr/bin/touch '"$make_expansion_marker"')'

expect_make_command_line_rejection() {
    make_target=$1
    make_variable=$2

    if (
        cd "$make_fixture"
        env -i \
            PATH="$PATH" \
            GHOSTTERM_RELEASE_CAPTURE="$make_command_line_release_capture" \
            GHOSTTERM_NOTARIZE_CAPTURE="$make_command_line_notarize_capture" \
            "$make_path" --no-print-directory "$make_target" "$make_variable=$literal_make_value"
    ) >"$make_command_line_output" 2>&1
    then
        fail "command-line $make_variable unexpectedly succeeded for $make_target"
    fi

    grep -F "$make_variable must be passed through the process environment before make" \
        "$make_command_line_output" >/dev/null \
        || fail "command-line $make_variable did not fail during Makefile parsing for $make_target"
    assert_missing "$make_expansion_marker"
}

for make_target in release notarize signed-alpha; do
    for make_variable in \
        DEVELOPMENT_TEAM \
        CODE_SIGN_IDENTITY \
        DMG \
        NOTARY_PROFILE \
        DEVELOPER_DIR \
        RELEASE_LABEL
    do
        expect_make_command_line_rejection "$make_target" "$make_variable"
    done
done
assert_missing "$make_command_line_release_capture"
assert_missing "$make_command_line_notarize_capture"

expect_make_command_line_developer_dir_acceptance() {
    make_target=$1

    if ! (
        cd "$make_fixture"
        env -i \
            PATH="$PATH" \
            "$make_path" --no-print-directory --dry-run "$make_target" "DEVELOPER_DIR=$test_developer_dir"
    ) >"$make_command_line_output" 2>&1
    then
        fail "command-line DEVELOPER_DIR unexpectedly failed for $make_target"
    fi
}

for make_target in build doctor generate; do
    expect_make_command_line_developer_dir_acceptance "$make_target"
done

run_make_fixture_dry_run() {
    make_target=$1
    make_release_capture_path=$2
    make_notarize_capture_path=$3
    make_developer_dir=$4

    (
        cd "$make_fixture"
        env -i \
            PATH="$PATH" \
            DEVELOPMENT_TEAM="$test_development_team" \
            CODE_SIGN_IDENTITY="$test_code_sign_identity" \
            DMG=".build/Release/$RELEASE_DMG_NAME" \
            NOTARY_PROFILE=fixture-notary \
            DEVELOPER_DIR="$make_developer_dir" \
            RELEASE_LABEL="$test_release_label" \
            GHOSTTERM_RELEASE_CAPTURE="$make_release_capture_path" \
            GHOSTTERM_NOTARIZE_CAPTURE="$make_notarize_capture_path" \
            "$make_path" --no-print-directory "$make_target"
    )
}

run_make_fixture_dry_run \
    release "$make_release_capture" "$tmp_root/unused-notarize-capture" "$test_developer_dir"
assert_make_capture "$make_release_capture" "$test_development_team" "$test_code_sign_identity" \
    ".build/Release/$RELEASE_DMG_NAME" fixture-notary "$test_developer_dir" "$test_release_label"

run_make_fixture_dry_run \
    notarize "$tmp_root/unused-release-capture" "$make_notarize_capture" "$test_developer_dir"
assert_make_capture "$make_notarize_capture" "$test_development_team" "$test_code_sign_identity" \
    ".build/Release/$RELEASE_DMG_NAME" fixture-notary "$test_developer_dir" "$test_release_label"

run_make_fixture_dry_run \
    signed-alpha "$make_signed_release_capture" "$make_signed_notarize_capture" "$test_developer_dir"
assert_make_capture "$make_signed_release_capture" "$test_development_team" "$test_code_sign_identity" \
    ".build/Release/$RELEASE_DMG_NAME" fixture-notary "$test_developer_dir" "$test_release_label"
assert_make_capture "$make_signed_notarize_capture" "$test_development_team" "$test_code_sign_identity" \
    ".build/Release/$RELEASE_DMG_NAME" fixture-notary "$test_developer_dir" "$test_release_label"

(
    cd "$make_fixture"
    env -i \
        PATH="$PATH" \
        DEVELOPMENT_TEAM="$test_development_team" \
        CODE_SIGN_IDENTITY="$test_code_sign_identity" \
        DMG=".build/Release/$RELEASE_DMG_NAME" \
        NOTARY_PROFILE=fixture-notary \
        RELEASE_LABEL="$test_release_label" \
        GHOSTTERM_RELEASE_CAPTURE="$make_default_release_capture" \
        "$make_path" --no-print-directory release
)
assert_make_capture "$make_default_release_capture" "$test_development_team" "$test_code_sign_identity" \
    ".build/Release/$RELEASE_DMG_NAME" fixture-notary "$default_developer_dir" "$test_release_label"

environment_literal_marker=$tmp_root/environment-literal-marker
environment_literal_value='$(shell /usr/bin/touch '"$environment_literal_marker"')'
environment_literal_output=$tmp_root/environment-literal-output
if (
    cd "$repo_root"
    env -i \
        PATH="$PATH" \
        TMPDIR="$TMPDIR" \
        DEVELOPMENT_TEAM="$test_development_team" \
        CODE_SIGN_IDENTITY="$test_code_sign_identity" \
        DMG="$environment_literal_value" \
        NOTARY_PROFILE=fixture-notary \
        "$make_path" --no-print-directory notarize
) >"$environment_literal_output" 2>&1
then
    fail 'process-environment literal unexpectedly succeeded for notarize'
fi
grep -F 'error: DMG is not an existing regular file:' "$environment_literal_output" >/dev/null \
    || fail 'process-environment literal did not reach notarization-script validation'
assert_missing "$environment_literal_marker"

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
