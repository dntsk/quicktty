#!/bin/sh
set -eu

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

expect_failure() {
    if [ -n "${tmp_root:-}" ]; then
        failure_output=$tmp_root/command-output
    else
        failure_output=/dev/null
    fi

    if "$@" >"$failure_output" 2>&1; then
        fail "expected command to fail: $*"
    fi
}

assert_missing() {
    [ ! -e "$1" ] && [ ! -L "$1" ] || fail "path should be absent: $1"
}

assert_equals() {
    [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

run_build_script_negative() {
    env DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY= sh -c '
        [ -z "${DEVELOPMENT_TEAM:-}" ] && [ -z "${CODE_SIGN_IDENTITY:-}" ] || {
            printf "%s\n" "error: negative build invocation inherited signing configuration" >&2
            exit 0
        }
        exec sh "$@"
    ' sh "$build_script" "$@"
}

expect_build_script_failure() {
    expected_message=$1
    shift

    if failure_output=$(run_build_script_negative "$@" 2>&1); then
        fail "expected build script to fail: $*"
    fi
    printf '%s\n' "$failure_output" | grep -F -x "$expected_message" >/dev/null \
        || fail "unexpected build script failure: $failure_output"
}

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P) || fail 'could not resolve test directory'
repo_root=$(CDPATH= cd -P "$script_dir/../.." && pwd -P) || fail 'could not resolve repository root'
helpers=$repo_root/scripts/release-helpers.sh
build_script=$repo_root/scripts/build-release.sh
ghostty_build_script=$repo_root/scripts/build-ghostty.sh
project_spec=$repo_root/project.yml

[ -f "$project_spec" ] || fail "project spec is missing: $project_spec"
[ -f "$helpers" ] || fail "release helpers are missing: $helpers"
[ -f "$build_script" ] || fail "release build script is missing: $build_script"
[ -f "$ghostty_build_script" ] || fail "Ghostty build script is missing: $ghostty_build_script"

sh -n "$helpers"
sh -n "$build_script"
sh -n "$ghostty_build_script"
grep -F -x 'PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin' "$build_script" >/dev/null \
    || fail 'release build script does not set the trusted PATH'
for required_build_setting in \
    'BUILD_NUMBER=3' \
    'BUNDLE_IDENTIFIER=com.dntsk.QuickTTY' \
    'PRODUCT_NAME=QuickTTY'
do
    grep -F -x "$required_build_setting" "$build_script" >/dev/null \
        || fail "release build script is missing required setting: $required_build_setting"
done
grep -F -x '    [ "$actual_display_name" = QuickTTY ] \' "$build_script" >/dev/null \
    || fail 'release build script does not require QuickTTY as CFBundleDisplayName'
grep -F -x '    [ "$actual_bundle_name" = QuickTTY ] \' "$build_script" >/dev/null \
    || fail 'release build script does not require QuickTTY as CFBundleName'
grep -F -x '    -project "$repo_root/QuickTTY.xcodeproj" \' "$build_script" >/dev/null \
    || fail 'release build script does not archive the QuickTTY project'
grep -F -x '    -scheme QuickTTY \' "$build_script" >/dev/null \
    || fail 'release build script does not archive the QuickTTY scheme'
grep -F -x 'QUICKTTY_FORCE_GHOSTTY_REBUILD=1 "$script_dir/build-ghostty.sh"' "$build_script" >/dev/null \
    || fail 'release build script does not force a Ghostty rebuild'
grep -F -x '        CURRENT_PROJECT_VERSION: 3' "$project_spec" >/dev/null \
    || fail 'project spec does not set CURRENT_PROJECT_VERSION to 3'

invalid_force_output=$(QUICKTTY_FORCE_GHOSTTY_REBUILD=invalid /bin/sh "$ghostty_build_script" 2>&1) \
    && fail 'invalid Ghostty force-rebuild flag unexpectedly succeeded'
printf '%s\n' "$invalid_force_output" \
    | grep -F -x 'error: QUICKTTY_FORCE_GHOSTTY_REBUILD must be unset, 0, or 1' >/dev/null \
    || fail "unexpected invalid force-rebuild failure: $invalid_force_output"

# These calls stop before tool discovery or any build/signing operation.
DEVELOPMENT_TEAM=N8FS9YUZQA
CODE_SIGN_IDENTITY='Developer ID Application: Dmitriy Lialiuev (N8FS9YUZQA)'
export DEVELOPMENT_TEAM CODE_SIGN_IDENTITY
expect_build_script_failure 'error: this script accepts no options or positional arguments' unexpected-option
expect_build_script_failure 'error: DEVELOPMENT_TEAM must be set'
APPLE_ID=unused
export APPLE_ID
expect_build_script_failure 'error: secret environment variable is not accepted: APPLE_ID'
unset APPLE_ID

. "$helpers"

assert_equals "$RELEASE_LABEL_DEFAULT" 0.1.0-beta.1
assert_equals "$RELEASE_ARCHIVE_NAME" QuickTTY.xcarchive
assert_equals "$RELEASE_DMG_NAME" QuickTTY-0.1.0-beta.1-arm64.dmg
assert_equals "$RELEASE_STAGE_NAME" QuickTTY-0.1.0-beta.1-stage
release_validate_label "$RELEASE_LABEL_DEFAULT"
release_validate_team N8FS9YUZQA
release_validate_identity 'Developer ID Application: Dmitriy Lialiuev (N8FS9YUZQA)'
signature_metadata='CodeDirectory v=20500 size=31839 flags=0x10000(runtime) hashes=984+7 location=embedded'
signature_metadata_multi='CodeDirectory v=20500 size=31839 flags=0x10000(adhoc,runtime,linker-signed) hashes=984+7 location=embedded'
release_signature_has_hardened_runtime "$signature_metadata"
release_signature_has_hardened_runtime "$signature_metadata_multi"
expect_failure sh -c '. "$1"; release_validate_label invalid' sh "$helpers"
expect_failure sh -c '. "$1"; release_validate_team invalid' sh "$helpers"
expect_failure sh -c '. "$1"; release_validate_identity "Apple Development: Example"' sh "$helpers"
expect_failure sh -c '. "$1"; release_signature_has_hardened_runtime "CodeDirectory flags=0x0"' sh "$helpers"
expect_failure sh -c '. "$1"; release_signature_has_hardened_runtime "CodeDirectory flags=0x0(none) note=runtime"' sh "$helpers"
expect_failure sh -c '. "$1"; release_signature_has_hardened_runtime "CodeDirectory flags=0x0 note=(runtime)"' sh "$helpers"
expect_failure sh -c '. "$1"; release_signature_has_hardened_runtime "CodeDirectory flags=0x10000(runtime-disabled)"' sh "$helpers"
expect_failure sh -c '. "$1"; release_signature_has_hardened_runtime "Identifier=runtime\nCodeDirectory flags=0x0(none)"' sh "$helpers"
expect_failure sh -c '. "$1"; release_signature_has_hardened_runtime "NotCodeDirectory flags=0x10000(runtime)"' sh "$helpers"
expect_failure env APPLE_PRIVATE_KEY_PATH=unused sh -c '. "$1"; release_reject_secret_environment' sh "$helpers"

tmp_base=${TMPDIR:-/tmp}
[ -n "$tmp_base" ] && [ "$tmp_base" != / ] || fail 'temporary directory base must not be empty or /'
tmp_base=$(CDPATH= cd -P "$tmp_base" && pwd -P) || fail "could not resolve temporary directory base: $tmp_base"
tmp_root=

cleanup() {
    status=$?
    trap - 0 HUP INT TERM

    if [ -n "$tmp_root" ] && [ -d "$tmp_root" ]; then
        case "$tmp_root" in
            "$tmp_base"/quicktty-release-test.*) rm -rf "$tmp_root" ;;
            *) printf 'error: refusing to remove unexpected temporary path: %s\n' "$tmp_root" >&2 ;;
        esac
    fi

    exit "$status"
}

trap cleanup 0 HUP INT TERM
tmp_root=$(mktemp -d "$tmp_base/quicktty-release-test.XXXXXX") || fail 'could not create temporary directory'
case "$tmp_root" in
    "$tmp_base"/quicktty-release-test.*) ;;
    *) fail "temporary directory has an unexpected path: $tmp_root" ;;
esac

malicious_bin=$tmp_root/malicious-bin
malicious_marker=$tmp_root/malicious-command-ran
malicious_output=$tmp_root/malicious-command-output
mkdir "$malicious_bin"
printf '#!/bin/sh\n: >"$QUICKTTY_MALICIOUS_MARKER"\nexit 99\n' >"$malicious_bin/dirname"
chmod +x "$malicious_bin/dirname"
if PATH="$malicious_bin:/usr/bin:/bin" \
    QUICKTTY_MALICIOUS_MARKER="$malicious_marker" \
    DEVELOPMENT_TEAM=N8FS9YUZQA \
    CODE_SIGN_IDENTITY='Developer ID Application: Dmitriy Lialiuev (N8FS9YUZQA)' \
    /bin/sh "$build_script" unexpected-option >"$malicious_output" 2>&1
then
    fail 'release build accepted an unexpected argument with a malicious inherited PATH'
fi
grep -F -x 'error: this script accepts no options or positional arguments' "$malicious_output" >/dev/null \
    || fail 'release build did not reach argument validation with a malicious inherited PATH'
assert_missing "$malicious_marker"

fixture_repo=$tmp_root/repository
mkdir "$fixture_repo"
release_dir=$(release_prepare_output_directory "$fixture_repo")
[ "$release_dir" = "$fixture_repo/.build/Release" ] || fail 'unexpected canonical release directory'

archive_path=$release_dir/$RELEASE_ARCHIVE_NAME
dmg_path=$release_dir/$RELEASE_DMG_NAME
notary_result_path=$release_dir/$RELEASE_NOTARY_RESULT_NAME
stage_path=$release_dir/$RELEASE_STAGE_NAME
historical_archive_path=$release_dir/GhostTerm.xcarchive
historical_dmg_path=$release_dir/GhostTerm-0.1.0-alpha.1-arm64.dmg
historical_notary_result_path=$historical_dmg_path.notary-result.json
historical_stage_path=$release_dir/GhostTerm-0.1.0-alpha.1-stage
unrelated_path=$release_dir/keep-me.txt
printf 'unrelated\n' >"$unrelated_path"
mkdir "$archive_path" "$stage_path" "$historical_archive_path" "$historical_stage_path"
printf 'generated\n' >"$dmg_path"
printf 'stale notarization result\n' >"$notary_result_path"
printf 'historical DMG\n' >"$historical_dmg_path"
printf 'historical notarization result\n' >"$historical_notary_result_path"

release_remove_generated_directory "$release_dir" "$archive_path"
release_remove_generated_directory "$release_dir" "$stage_path"
release_remove_generated_file "$release_dir" "$dmg_path"
release_remove_generated_file "$release_dir" "$notary_result_path"
assert_missing "$archive_path"
assert_missing "$stage_path"
assert_missing "$dmg_path"
assert_missing "$notary_result_path"
[ -d "$historical_archive_path" ] || fail 'cleanup removed the historical archive'
[ -d "$historical_stage_path" ] || fail 'cleanup removed the historical staging directory'
[ -f "$historical_dmg_path" ] || fail 'cleanup removed the historical DMG'
[ -f "$historical_notary_result_path" ] || fail 'cleanup removed the historical notarization evidence'
[ -f "$unrelated_path" ] || fail 'cleanup modified an unrelated release file'
expect_failure sh -c '. "$1"; release_remove_generated_directory "$2" "$3"' sh \
    "$helpers" "$release_dir" "$historical_archive_path"
expect_failure sh -c '. "$1"; release_remove_generated_file "$2" "$3"' sh \
    "$helpers" "$release_dir" "$historical_dmg_path"
release_assert_generated_path_absent "$release_dir" "$dmg_path"
printf 'race\n' >"$dmg_path"
expect_failure sh -c '. "$1"; release_assert_generated_path_absent "$2" "$3"' sh \
    "$helpers" "$release_dir" "$dmg_path"
rm "$dmg_path"
ln -s "$unrelated_path" "$dmg_path"
expect_failure sh -c '. "$1"; release_assert_generated_path_absent "$2" "$3"' sh \
    "$helpers" "$release_dir" "$dmg_path"
rm "$dmg_path"
ln -s "$unrelated_path" "$notary_result_path"
expect_failure sh -c '. "$1"; release_remove_generated_file "$2" "$3"' sh \
    "$helpers" "$release_dir" "$notary_result_path"
[ -L "$notary_result_path" ] || fail 'notarization-result cleanup removed a symlink'
rm "$notary_result_path"

mkdir "$tmp_root/symlink-target"
ln -s "$tmp_root/symlink-target" "$stage_path"
expect_failure sh -c '. "$1"; release_remove_generated_directory "$2" "$3"' sh \
    "$helpers" "$release_dir" "$stage_path"
[ -L "$stage_path" ] || fail 'symlink protection removed the staged symlink'
rm "$stage_path"

ln -s "$fixture_repo" "$tmp_root/repository-link"
expect_failure sh -c '. "$1"; release_prepare_output_directory "$2"' sh \
    "$helpers" "$tmp_root/repository-link"

expect_failure sh -c '. "$1"; release_assert_generated_path "$2" /' sh \
    "$helpers" "$release_dir"

resource_share=$fixture_repo/Vendor/ghostty/zig-out/share
resource_terminfo=$resource_share/terminfo
resource_ghostty=$resource_share/ghostty
mkdir -p "$resource_terminfo" "$resource_ghostty"
printf 'stale terminfo\n' >"$resource_terminfo/stale-file"
printf 'stale Ghostty resource\n' >"$resource_ghostty/stale-file"
printf 'preserve share root\n' >"$resource_share/keep-me"
release_force_clean_ghostty_generated_resources "$fixture_repo"
assert_missing "$resource_terminfo"
assert_missing "$resource_ghostty"
[ -f "$resource_share/keep-me" ] || fail 'Ghostty resource cleanup removed an unrelated share file'
mkdir "$tmp_root/ghostty-resource-symlink-target"
ln -s "$tmp_root/ghostty-resource-symlink-target" "$resource_terminfo"
expect_failure sh -c '. "$1"; release_force_clean_ghostty_generated_resources "$2"' sh \
    "$helpers" "$fixture_repo"
[ -L "$resource_terminfo" ] || fail 'Ghostty resource cleanup removed a symlink'
rm "$resource_terminfo"
expect_failure sh -c '. "$1"; release_remove_ghostty_generated_resource_directory "$2" "$3"' sh \
    "$helpers" "$fixture_repo" "$resource_share/unexpected"

provenance_repo=$tmp_root/provenance-repository
mkdir "$provenance_repo"
/usr/bin/git -C "$provenance_repo" init -q
printf 'tracked\n' >"$provenance_repo/tracked.txt"
printf 'ignored.txt\n' >"$provenance_repo/.gitignore"
/usr/bin/git -C "$provenance_repo" add tracked.txt .gitignore
/usr/bin/git -C "$provenance_repo" -c user.name=QuickTTY -c user.email=release-test@example.invalid \
    commit -qm 'fixture'
assert_equals "$(release_source_tree_state "$provenance_repo" /usr/bin/git)" clean
printf 'tracked change\n' >"$provenance_repo/tracked.txt"
assert_equals "$(release_source_tree_state "$provenance_repo" /usr/bin/git)" dirty
printf 'tracked\n' >"$provenance_repo/tracked.txt"
printf 'staged change\n' >"$provenance_repo/tracked.txt"
/usr/bin/git -C "$provenance_repo" add tracked.txt
assert_equals "$(release_source_tree_state "$provenance_repo" /usr/bin/git)" dirty
printf 'tracked\n' >"$provenance_repo/tracked.txt"
/usr/bin/git -C "$provenance_repo" add tracked.txt
touch "$provenance_repo/untracked.txt"
assert_equals "$(release_source_tree_state "$provenance_repo" /usr/bin/git)" dirty
rm "$provenance_repo/untracked.txt"
touch "$provenance_repo/ignored.txt"
assert_equals "$(release_source_tree_state "$provenance_repo" /usr/bin/git)" clean

layout_app=$tmp_root/Layout.app
layout_macos=$layout_app/Contents/MacOS
layout_resources=$layout_app/Contents/Resources
mkdir -p "$layout_macos" "$layout_resources"
cp /usr/bin/true "$layout_macos/QuickTTY"
printf '#!/bin/sh\nexit 0\n' >"$layout_resources/resource-script.sh"
chmod +x "$layout_resources/resource-script.sh"
release_verify_app_code_layout "$layout_app" QuickTTY /usr/bin/file
mkdir "$layout_app/Contents/Frameworks"
release_verify_app_code_layout "$layout_app" QuickTTY /usr/bin/file
touch "$layout_app/Contents/Frameworks/unexpected"
expect_failure sh -c '. "$1"; release_verify_app_code_layout "$2" QuickTTY /usr/bin/file' sh \
    "$helpers" "$layout_app"
rm "$layout_app/Contents/Frameworks/unexpected"
cp /usr/bin/true "$layout_resources/nested-macho"
expect_failure sh -c '. "$1"; release_verify_app_code_layout "$2" QuickTTY /usr/bin/file' sh \
    "$helpers" "$layout_app"
rm "$layout_resources/nested-macho"
touch "$layout_macos/unexpected"
expect_failure sh -c '. "$1"; release_verify_app_code_layout "$2" QuickTTY /usr/bin/file' sh \
    "$helpers" "$layout_app"
rm "$layout_macos/unexpected"

symlink_main_app=$tmp_root/SymlinkMain.app
mkdir -p "$symlink_main_app/Contents/MacOS"
ln -s /usr/bin/true "$symlink_main_app/Contents/MacOS/QuickTTY"
expect_failure sh -c '. "$1"; release_verify_app_code_layout "$2" QuickTTY /usr/bin/file' sh \
    "$helpers" "$symlink_main_app"

printf 'QuickTTY release helper tests passed.\n'
