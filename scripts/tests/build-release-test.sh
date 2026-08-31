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
app_info_plist=$repo_root/QuickTTY/Resources/Info.plist

[ -f "$project_spec" ] || fail "project spec is missing: $project_spec"
[ -f "$app_info_plist" ] || fail "app Info.plist is missing: $app_info_plist"
[ -f "$helpers" ] || fail "release helpers are missing: $helpers"
[ -f "$build_script" ] || fail "release build script is missing: $build_script"
[ -f "$ghostty_build_script" ] || fail "Ghostty build script is missing: $ghostty_build_script"

sh -n "$helpers"
sh -n "$build_script"
sh -n "$ghostty_build_script"
grep -F -x 'PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin' "$build_script" >/dev/null \
    || fail 'release build script does not set the trusted PATH'
for required_build_setting in \
    'BUILD_NUMBER=10' \
    'BUNDLE_IDENTIFIER=com.dntsk.QuickTTY' \
    'MARKETING_VERSION=0.1.3' \
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
cli_phase_gate_line=$(grep -nF -x '          if [ "$ACTION" != install ]; then' "$project_spec" \
    | /usr/bin/cut -d: -f1)
cli_phase_copy_line=$(grep -nF -x '            "$SRCROOT/scripts/copy-cli-helper.sh" \' "$project_spec" \
    | /usr/bin/cut -d: -f1)
cli_phase_end_line=$(grep -nF -x '          fi' "$project_spec" | /usr/bin/cut -d: -f1)
[ -n "$cli_phase_gate_line" ] && [ -n "$cli_phase_copy_line" ] && [ -n "$cli_phase_end_line" ] \
    && [ "$cli_phase_gate_line" -lt "$cli_phase_copy_line" ] \
    && [ "$cli_phase_copy_line" -lt "$cli_phase_end_line" ] \
    || fail 'CLI helper post-build phase must copy only when ACTION is not install'
grep -F -x 'CLI_HELPER_IDENTIFIER=com.dntsk.QuickTTY.cli' "$build_script" >/dev/null \
    || fail 'release build script does not use the exact CLI helper identifier'
helper_identifier_line=$(grep -nF -x '    --identifier "$CLI_HELPER_IDENTIFIER" \' "$build_script" \
    | /usr/bin/cut -d: -f1)
[ -n "$helper_identifier_line" ] || fail 'release build script does not pass the CLI helper identifier to codesign'
helper_sign_line=$((helper_identifier_line - 1))
[ "$(/usr/bin/awk -v line="$helper_sign_line" 'NR == line { print }' "$build_script")" = \
    '"$codesign_path" --force --sign "$CODE_SIGN_IDENTITY" --timestamp --options runtime \' ] \
    || fail 'CLI helper codesign options or order are not exact'
archive_bundle_verification_line=$(grep -nF -x 'verify_bundle "$archive_app"' "$build_script" \
    | /usr/bin/cut -d: -f1)
cli_stage_copy_line=$(grep -nF -x '"$script_dir/copy-cli-helper.sh" \' "$build_script" \
    | /usr/bin/cut -d: -f1)
[ -n "$archive_bundle_verification_line" ] && [ -n "$cli_stage_copy_line" ] \
    && [ "$archive_bundle_verification_line" -lt "$cli_stage_copy_line" ] \
    && [ "$cli_stage_copy_line" -lt "$helper_sign_line" ] \
    || fail 'release build must separately stage the CLI helper after bundle verification and before signing'
sparkle_layout_line=$(grep -nF -x 'release_verify_sparkle_signing_layout "$staged_app"' \
    "$build_script" | /usr/bin/cut -d: -f1)
[ -n "$sparkle_layout_line" ] && [ "$sparkle_layout_line" -lt "$helper_sign_line" ] \
    || fail 'staged Sparkle layout must be validated before any codesign invocation'
sparkle_sign_line=$(grep -nF -x \
    '    "$staged_app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \' \
    "$build_script" | /usr/bin/cut -d: -f1)
outer_app_sign_line=$(grep -nF -x '    "$staged_app" \' "$build_script" | /usr/bin/cut -d: -f1)
outer_app_verification_line=$(grep -nF -x 'verify_signed_app_bundle "$staged_app"' "$build_script" \
    | /usr/bin/cut -d: -f1)
[ "$helper_sign_line" -lt "$sparkle_sign_line" ] \
    && [ "$sparkle_sign_line" -lt "$outer_app_sign_line" ] \
    && [ "$outer_app_sign_line" -lt "$outer_app_verification_line" ] \
    || fail 'signing order must be CLI helper, Sparkle, outer app, then verification'
grep -F -x '        CURRENT_PROJECT_VERSION: 10' "$project_spec" >/dev/null \
    || fail 'project spec does not set CURRENT_PROJECT_VERSION to 10'
grep -F -x '        GENERATE_INFOPLIST_FILE: NO' "$project_spec" >/dev/null \
    || fail 'project spec does not disable generated app Info.plist'
grep -F -x '        GENERATE_INFOPLIST_FILE: YES' "$project_spec" >/dev/null \
    || fail 'project spec does not generate the test Info.plist'
grep -F -x '        INFOPLIST_FILE: QuickTTY/Resources/Info.plist' "$project_spec" >/dev/null \
    || fail 'project spec does not use the app Info.plist'
grep -F -x '        MARKETING_VERSION: 0.1.3' "$project_spec" >/dev/null \
    || fail 'project spec does not set MARKETING_VERSION to 0.1.3'
grep -F -x '    <key>CFBundleExecutable</key>' "$app_info_plist" >/dev/null \
    || fail 'app Info.plist does not define CFBundleExecutable'
grep -F -x '    <string>$(EXECUTABLE_NAME)</string>' "$app_info_plist" >/dev/null \
    || fail 'app Info.plist does not use the product executable name'
grep -F -x '    <key>CFBundleIconFile</key>' "$app_info_plist" >/dev/null \
    || fail 'app Info.plist does not define CFBundleIconFile'
grep -F -x '    <key>CFBundleIconName</key>' "$app_info_plist" >/dev/null \
    || fail 'app Info.plist does not define CFBundleIconName'
grep -F -x '    <string>AppIcon</string>' "$app_info_plist" >/dev/null \
    || fail 'app Info.plist does not set AppIcon'
grep -F -x '    <key>SUPublicEDKey</key>' "$app_info_plist" >/dev/null \
    || fail 'app Info.plist does not define the Sparkle Ed25519 public key'
grep -F -x '    <string>e7y/m6sTWYFRLzJiBlvus8EZs8oeZ6nyQzayNfJEdrU=</string>' "$app_info_plist" >/dev/null \
    || fail 'app Info.plist does not set the Sparkle Ed25519 public key'

invalid_force_output=$(QUICKTTY_FORCE_GHOSTTY_REBUILD=invalid /bin/sh "$ghostty_build_script" 2>&1) \
    && fail 'invalid Ghostty force-rebuild flag unexpectedly succeeded'
printf '%s\n' "$invalid_force_output" \
    | grep -F -x 'error: QUICKTTY_FORCE_GHOSTTY_REBUILD must be unset, 0, or 1' >/dev/null \
    || fail "unexpected invalid force-rebuild failure: $invalid_force_output"
ghostty_cache_reuse_exit_line=$(grep -nF -x '    exit 0' "$ghostty_build_script" \
    | /usr/bin/cut -d: -f1)
ghostty_cache_cleanup_line=$(grep -nF -x 'remove_zig_cache_before_rebuild' "$ghostty_build_script" \
    | /usr/bin/cut -d: -f1)
ghostty_zig_build_line=$(grep -nF -x '    zig build "$@"' "$ghostty_build_script" \
    | /usr/bin/cut -d: -f1)
[ -n "$ghostty_cache_reuse_exit_line" ] && [ -n "$ghostty_cache_cleanup_line" ] \
    && [ -n "$ghostty_zig_build_line" ] \
    && [ "$ghostty_cache_reuse_exit_line" -lt "$ghostty_cache_cleanup_line" ] \
    && [ "$ghostty_cache_cleanup_line" -lt "$ghostty_zig_build_line" ] \
    || fail 'Ghostty Zig cache cleanup must run after successful cache reuse exits and before a real zig build'

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

assert_equals "$RELEASE_LABEL_DEFAULT" 0.1.3.beta-1
assert_equals "$RELEASE_ARCHIVE_NAME" QuickTTY.xcarchive
assert_equals "$RELEASE_DMG_NAME" QuickTTY-0.1.3.beta-1-arm64.dmg
assert_equals "$RELEASE_STAGE_NAME" QuickTTY-0.1.3.beta-1-stage
assert_equals "$RELEASE_APPCAST_DIRECTORY_NAME" appcast
assert_equals "$RELEASE_APPCAST_NAME" appcast.xml
assert_equals "$(release_appcast_download_url_prefix)" \
    https://github.com/dntsk/quicktty/releases/download/v0.1.3.beta-1/
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
TMPDIR=$tmp_root
export TMPDIR

ghostty_cleanup_function_fixture=$tmp_root/build-ghostty-cleanup-function.sh
/usr/bin/awk '
    /^remove_zig_cache_before_rebuild\(\) \{/ { capture = 1 }
    capture {
        print
        if ($0 == "}") exit
    }
' "$ghostty_build_script" >"$ghostty_cleanup_function_fixture"
. "$ghostty_cleanup_function_fixture"
ghostty_cleanup_fixture=$tmp_root/ghostty-cache-cleanup
zig_cache_dir=$ghostty_cleanup_fixture/.zig-cache
mkdir -p "$zig_cache_dir"
printf 'stale build artifact\n' >"$zig_cache_dir/stale"
cleanup_output=$(remove_zig_cache_before_rebuild 2>&1)
assert_equals "$cleanup_output" \
    "Removing generated Ghostty Zig cache directory before rebuild: $zig_cache_dir"
assert_missing "$zig_cache_dir"
mkdir -p "$ghostty_cleanup_fixture/symlink-target"
ln -s "$ghostty_cleanup_fixture/symlink-target" "$zig_cache_dir"
if (remove_zig_cache_before_rebuild) >"$tmp_root/command-output" 2>&1; then
    fail 'Ghostty Zig cache cleanup accepted a symlink'
fi
grep -F -x \
    "error: refusing to remove generated Ghostty Zig cache directory symlink: $zig_cache_dir" \
    "$tmp_root/command-output" >/dev/null \
    || fail 'Ghostty Zig cache cleanup produced an unexpected symlink error'
[ -L "$zig_cache_dir" ] || fail 'Ghostty Zig cache cleanup removed a symlink'
rm "$zig_cache_dir"
printf 'unexpected file\n' >"$zig_cache_dir"
if (remove_zig_cache_before_rebuild) >"$tmp_root/command-output" 2>&1; then
    fail 'Ghostty Zig cache cleanup accepted a non-directory path'
fi
grep -F -x \
    "error: generated Ghostty Zig cache path is not a directory: $zig_cache_dir" \
    "$tmp_root/command-output" >/dev/null \
    || fail 'Ghostty Zig cache cleanup produced an unexpected non-directory error'
[ -f "$zig_cache_dir" ] || fail 'Ghostty Zig cache cleanup removed a non-directory path'

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
appcast_path=$release_dir/$RELEASE_APPCAST_DIRECTORY_NAME
historical_archive_path=$release_dir/GhostTerm.xcarchive
historical_dmg_path=$release_dir/GhostTerm-0.1.0-alpha.1-arm64.dmg
historical_notary_result_path=$historical_dmg_path.notary-result.json
historical_stage_path=$release_dir/GhostTerm-0.1.0-alpha.1-stage
unrelated_path=$release_dir/keep-me.txt
printf 'unrelated\n' >"$unrelated_path"
mkdir "$archive_path" "$stage_path" "$appcast_path" "$historical_archive_path" "$historical_stage_path"
printf 'generated\n' >"$dmg_path"
printf 'stale notarization result\n' >"$notary_result_path"
printf 'historical DMG\n' >"$historical_dmg_path"
printf 'historical notarization result\n' >"$historical_notary_result_path"

release_remove_generated_directory "$release_dir" "$archive_path"
release_remove_generated_directory "$release_dir" "$appcast_path"
release_remove_generated_directory "$release_dir" "$stage_path"
release_remove_generated_file "$release_dir" "$dmg_path"
release_remove_generated_file "$release_dir" "$notary_result_path"
assert_missing "$archive_path"
assert_missing "$appcast_path"
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
release_assert_generated_path_absent "$release_dir" "$appcast_path"
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

appcast_fixture_dmg=$tmp_root/$RELEASE_DMG_NAME
appcast_fixture=$tmp_root/$RELEASE_APPCAST_NAME
printf 'final DMG\n' >"$appcast_fixture_dmg"
appcast_fixture_size=$(/usr/bin/stat -f '%z' "$appcast_fixture_dmg")
printf '<enclosure url="%s%s" sparkle:edSignature="fixture" length="%s" type="application/octet-stream"/>\n' \
    "$(release_appcast_download_url_prefix)" "$RELEASE_DMG_NAME" "$appcast_fixture_size" >"$appcast_fixture"
release_verify_appcast "$appcast_fixture" "$appcast_fixture_dmg" /usr/bin/stat /usr/bin/grep
printf '<enclosure url="%s" length="%s" type="application/octet-stream"/>\n' \
    "$RELEASE_DMG_NAME" "$appcast_fixture_size" >"$appcast_fixture"
expect_failure sh -c '. "$1"; release_verify_appcast "$2" "$3" /usr/bin/stat /usr/bin/grep' sh \
    "$helpers" "$appcast_fixture" "$appcast_fixture_dmg"

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
layout_helpers=$layout_app/Contents/Helpers
mkdir -p "$layout_macos" "$layout_resources" "$layout_helpers"
cp /usr/bin/true "$layout_macos/QuickTTY"
printf 'fixture arm64 executable\n' >"$layout_helpers/quicktty"
chmod 755 "$layout_helpers/quicktty"
printf '#!/bin/sh\nexit 0\n' >"$layout_resources/resource-script.sh"
chmod +x "$layout_resources/resource-script.sh"
release_verify_app_code_layout "$layout_app" QuickTTY /usr/bin/file
layout_frameworks=$layout_app/Contents/Frameworks
layout_later_operation=$tmp_root/layout-later-security-operation
expect_layout_failure_before_later_operation() {
    rm -f "$layout_later_operation"
    if (release_verify_app_code_layout "$layout_app" QuickTTY /usr/bin/file; \
        : >"$layout_later_operation") >"$tmp_root/command-output" 2>&1
    then
        fail 'expected Frameworks layout verification to fail'
    fi
    assert_missing "$layout_later_operation"
}

mkdir "$layout_frameworks"
release_verify_app_code_layout "$layout_app" QuickTTY /usr/bin/file
mkdir "$tmp_root/frameworks-symlink-target"
rm -rf "$layout_frameworks"
ln -s "$tmp_root/frameworks-symlink-target" "$layout_frameworks"
expect_layout_failure_before_later_operation
rm "$layout_frameworks"
mkdir "$layout_frameworks"
touch "$layout_frameworks/.hidden"
expect_layout_failure_before_later_operation
rm "$layout_frameworks/.hidden"
touch "$layout_frameworks/..hidden"
expect_layout_failure_before_later_operation
rm "$layout_frameworks/..hidden"
touch "$layout_frameworks/unexpected"
expect_layout_failure_before_later_operation
rm "$layout_frameworks/unexpected"
cp /usr/bin/true "$layout_resources/nested-macho"
expect_failure sh -c '. "$1"; release_verify_app_code_layout "$2" QuickTTY /usr/bin/file' sh \
    "$helpers" "$layout_app"
rm "$layout_resources/nested-macho"
touch "$layout_macos/unexpected"
expect_failure sh -c '. "$1"; release_verify_app_code_layout "$2" QuickTTY /usr/bin/file' sh \
    "$helpers" "$layout_app"
rm "$layout_macos/unexpected"

integration_function_fixture=$tmp_root/build-release-integration-functions.sh
/usr/bin/awk '
    /^require_regular_file\(\) \{/ { capture = 1 }
    /^plist_value\(\) \{/ { capture = 0 }
    capture { print }
' "$build_script" >"$integration_function_fixture"
. "$integration_function_fixture"
stat_path=/usr/bin/stat

integration_fixture_resources=$tmp_root/IntegrationResources
reset_integration_fixture() {
    rm -rf "$integration_fixture_resources"
    mkdir -p "$integration_fixture_resources"
    cp -R "$repo_root/QuickTTY/Resources/AgentSessionIntegrations" \
        "$integration_fixture_resources/AgentSessionIntegrations"
}
expect_integration_fixture_failure() {
    if (verify_agent_session_integrations "$integration_fixture_resources") \
        >"$tmp_root/command-output" 2>&1
    then
        fail 'expected AgentSessionIntegrations verification to fail'
    fi
}

reset_integration_fixture
verify_agent_session_integrations "$integration_fixture_resources"
rm -rf "$integration_fixture_resources/AgentSessionIntegrations"
expect_integration_fixture_failure
reset_integration_fixture
rm "$integration_fixture_resources/AgentSessionIntegrations/pi/index.ts"
expect_integration_fixture_failure
reset_integration_fixture
printf 'corrupted\n' >"$integration_fixture_resources/AgentSessionIntegrations/pi/index.ts"
expect_integration_fixture_failure
reset_integration_fixture
rm "$integration_fixture_resources/AgentSessionIntegrations/pi/index.ts"
ln -s /usr/bin/true "$integration_fixture_resources/AgentSessionIntegrations/pi/index.ts"
expect_integration_fixture_failure
reset_integration_fixture
mkdir "$integration_fixture_resources/AgentSessionIntegrations/grok"
expect_integration_fixture_failure
reset_integration_fixture
touch "$integration_fixture_resources/AgentSessionIntegrations/unknown-resource"
expect_integration_fixture_failure
reset_integration_fixture
chmod 644 "$integration_fixture_resources/AgentSessionIntegrations/amp/wrapper/amp"
expect_integration_fixture_failure

build_function_fixture=$tmp_root/build-release-functions.sh
/usr/bin/awk '
    /^verify_signature_metadata\(\) \{/ { capture = 1 }
    /^verify_bundle\(\) \{/ { capture = 0 }
    capture { print }
' "$build_script" >"$build_function_fixture"
. "$build_function_fixture"

mock_tools=$tmp_root/mock-tools
mock_signature_metadata=$tmp_root/mock-signature-metadata
mock_entitlements=$tmp_root/mock-entitlements
mock_file_description=$tmp_root/mock-file-description
mock_lipo_architectures=$tmp_root/mock-lipo-architectures
mock_codesign_log=$tmp_root/mock-codesign-log
mkdir "$mock_tools"
printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    'printf "%s\n" "$*" >>"$QUICKTTY_MOCK_CODESIGN_LOG"' \
    'if [ "$1" = -d ] && [ "$2" = -vvv ]; then cat "$QUICKTTY_MOCK_SIGNATURE_METADATA" >&2; exit 0; fi' \
    'if [ "$1" = -d ] && [ "$2" = --entitlements ]; then cat "$QUICKTTY_MOCK_ENTITLEMENTS"; exit 0; fi' \
    'if [ "$1" = --verify ]; then exit 0; fi' \
    'exit 97' >"$mock_tools/codesign"
printf '%s\n' \
    '#!/bin/sh' \
    'if [ -n "${QUICKTTY_MOCK_MACHO_PATH:-}" ] && [ "${2:-}" != "$QUICKTTY_MOCK_MACHO_PATH" ]; then printf "%s\\n" data; else cat "$QUICKTTY_MOCK_FILE_DESCRIPTION"; fi' \
    >"$mock_tools/file"
printf '%s\n' '#!/bin/sh' 'cat "$QUICKTTY_MOCK_LIPO_ARCHITECTURES"' >"$mock_tools/lipo"
chmod +x "$mock_tools/codesign" "$mock_tools/file" "$mock_tools/lipo"

codesign_path=$mock_tools/codesign
file_path=$mock_tools/file
lipo_path=$mock_tools/lipo
stat_path=/usr/bin/stat
CLI_HELPER_NAME=quicktty
CLI_HELPER_IDENTIFIER=com.dntsk.QuickTTY.cli
export QUICKTTY_MOCK_CODESIGN_LOG="$mock_codesign_log"
export QUICKTTY_MOCK_SIGNATURE_METADATA="$mock_signature_metadata"
export QUICKTTY_MOCK_ENTITLEMENTS="$mock_entitlements"
export QUICKTTY_MOCK_FILE_DESCRIPTION="$mock_file_description"
export QUICKTTY_MOCK_LIPO_ARCHITECTURES="$mock_lipo_architectures"

cli_fixture_app=$tmp_root/CLIHelper.app
cli_fixture_helpers=$cli_fixture_app/Contents/Helpers
cli_fixture_helper=$cli_fixture_helpers/quicktty
reset_cli_fixture() {
    rm -rf "$cli_fixture_app"
    mkdir -p "$cli_fixture_helpers"
    printf 'fixture arm64 executable\n' >"$cli_fixture_helper"
    chmod 755 "$cli_fixture_helper"
    printf '%s\n' \
        'Identifier=com.dntsk.QuickTTY.cli' \
        "Authority=$CODE_SIGN_IDENTITY" \
        "TeamIdentifier=$DEVELOPMENT_TEAM" \
        'Timestamp=Aug 7, 2026 at 12:00:00' \
        'CodeDirectory flags=0x10000(runtime)' >"$mock_signature_metadata"
    : >"$mock_entitlements"
    printf '%s\n' 'Mach-O 64-bit executable arm64' >"$mock_file_description"
    printf '%s\n' arm64 >"$mock_lipo_architectures"
    : >"$mock_codesign_log"
}

expect_cli_fixture_failure() {
    if (verify_cli_helper_signature "$cli_fixture_app") >"$tmp_root/command-output" 2>&1; then
        fail 'expected CLI helper verification to fail'
    fi
}

reset_cli_fixture
verify_cli_helper_signature "$cli_fixture_app"
grep -F -x -- "--verify --strict --verbose=4 $cli_fixture_helper" "$mock_codesign_log" >/dev/null \
    || fail 'CLI helper strict signature verification was not invoked'
grep -F -x -- "-d -vvv $cli_fixture_helper" "$mock_codesign_log" >/dev/null \
    || fail 'CLI helper signature metadata was not inspected'
grep -F -x -- "-d --entitlements :- $cli_fixture_helper" "$mock_codesign_log" >/dev/null \
    || fail 'CLI helper entitlements were not inspected'

reset_cli_fixture
rm "$cli_fixture_helper"
expect_cli_fixture_failure
reset_cli_fixture
touch "$cli_fixture_helpers/extra"
expect_cli_fixture_failure
reset_cli_fixture
mkdir "$cli_fixture_helpers/extra-directory"
expect_cli_fixture_failure
reset_cli_fixture
rm "$cli_fixture_helper"
ln -s /usr/bin/true "$cli_fixture_helper"
expect_cli_fixture_failure
reset_cli_fixture
rm "$cli_fixture_helper"
mkdir "$cli_fixture_helper"
expect_cli_fixture_failure
reset_cli_fixture
chmod 644 "$cli_fixture_helper"
expect_cli_fixture_failure
reset_cli_fixture
chmod 775 "$cli_fixture_helper"
expect_cli_fixture_failure
reset_cli_fixture
printf '%s\n' 'arm64 x86_64' >"$mock_lipo_architectures"
expect_cli_fixture_failure
reset_cli_fixture
printf '%s\n' x86_64 >"$mock_lipo_architectures"
expect_cli_fixture_failure
reset_cli_fixture
/usr/bin/sed -i '' 's/Identifier=com.dntsk.QuickTTY.cli/Identifier=com.dntsk.QuickTTY.wrong/' \
    "$mock_signature_metadata"
expect_cli_fixture_failure
reset_cli_fixture
/usr/bin/sed -i '' 's/CodeDirectory flags=0x10000(runtime)/CodeDirectory flags=0x0(none)/' \
    "$mock_signature_metadata"
expect_cli_fixture_failure
reset_cli_fixture
/usr/bin/sed -i '' "s|Authority=$CODE_SIGN_IDENTITY|Authority=Developer ID Application: Wrong (WRONG12345)|" \
    "$mock_signature_metadata"
expect_cli_fixture_failure
reset_cli_fixture
/usr/bin/sed -i '' "s/TeamIdentifier=$DEVELOPMENT_TEAM/TeamIdentifier=WRONG12345/" \
    "$mock_signature_metadata"
expect_cli_fixture_failure
reset_cli_fixture
printf '%s\n' '<plist><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>' \
    >"$mock_entitlements"
expect_cli_fixture_failure

nested_fixture_app=$tmp_root/NestedCode.app
nested_sparkle=$nested_fixture_app/Contents/Frameworks/Sparkle.framework/Versions/B
nested_autoupdate=$nested_sparkle/Autoupdate
nested_later_operation=$tmp_root/nested-later-security-operation
mkdir -p \
    "$nested_sparkle/XPCServices/Installer.xpc/Contents/MacOS" \
    "$nested_sparkle/XPCServices/Downloader.xpc/Contents/MacOS" \
    "$nested_sparkle/Updater.app/Contents/MacOS"
for nested_fixture_executable in \
    "$nested_autoupdate" \
    "$nested_sparkle/Sparkle" \
    "$nested_sparkle/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
    "$nested_sparkle/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    "$nested_sparkle/Updater.app/Contents/MacOS/Updater"
do
    printf 'fixture Mach-O\n' >"$nested_fixture_executable"
    chmod 755 "$nested_fixture_executable"
done
export QUICKTTY_MOCK_MACHO_PATH="$nested_autoupdate"
reset_nested_signature_metadata() {
    printf '%s\n' \
        'Identifier=Autoupdate-fixture' \
        "Authority=$CODE_SIGN_IDENTITY" \
        "TeamIdentifier=$DEVELOPMENT_TEAM" \
        'Timestamp=Aug 7, 2026 at 12:00:00' \
        'CodeDirectory flags=0x10000(runtime)' >"$mock_signature_metadata"
    : >"$mock_codesign_log"
    rm -f "$nested_later_operation"
}
expect_nested_failure_before_later_operation() {
    if (release_verify_nested_code_recursively \
        "$nested_fixture_app" "$codesign_path" "$file_path" \
        "$CODE_SIGN_IDENTITY" "$DEVELOPMENT_TEAM"; \
        "$codesign_path" --verify --strict --deep --verbose=4 "$nested_fixture_app"; \
        : >"$nested_later_operation") >"$tmp_root/command-output" 2>&1
    then
        fail 'expected nested code verification to fail'
    fi
    assert_missing "$nested_later_operation"
    if grep -F -x -- "--verify --strict --deep --verbose=4 $nested_fixture_app" \
        "$mock_codesign_log" >/dev/null
    then
        fail 'outer app verification ran after nested code verification failed'
    fi
}

reset_nested_signature_metadata
release_verify_nested_code_recursively \
    "$nested_fixture_app" "$codesign_path" "$file_path" \
    "$CODE_SIGN_IDENTITY" "$DEVELOPMENT_TEAM"
grep -F -x -- "--verify --strict --verbose=4 $nested_autoupdate" "$mock_codesign_log" >/dev/null \
    || fail 'nested Mach-O strict verification was not invoked'
grep -F -x -- "-d -vvv $nested_autoupdate" "$mock_codesign_log" >/dev/null \
    || fail 'nested Mach-O signature metadata was not inspected'

reset_nested_signature_metadata
mock_find_failure=$mock_tools/find-failure
printf '%s\n' '#!/bin/sh' 'exit 73' >"$mock_find_failure"
chmod +x "$mock_find_failure"
release_real_find_path=$RELEASE_FIND_PATH
RELEASE_FIND_PATH=$mock_find_failure
expect_nested_failure_before_later_operation
RELEASE_FIND_PATH=$release_real_find_path
for nested_code_list in "$TMPDIR"/quicktty-nested-code.*; do
    [ ! -e "$nested_code_list" ] && [ ! -L "$nested_code_list" ] \
        || fail "nested code list leaked after find failure: $nested_code_list"
done

reset_nested_signature_metadata
/usr/bin/sed -i '' "s|Authority=$CODE_SIGN_IDENTITY|Authority=Developer ID Application: Wrong (WRONG12345)|" \
    "$mock_signature_metadata"
expect_nested_failure_before_later_operation
reset_nested_signature_metadata
/usr/bin/sed -i '' "s/TeamIdentifier=$DEVELOPMENT_TEAM/TeamIdentifier=WRONG12345/" \
    "$mock_signature_metadata"
expect_nested_failure_before_later_operation
reset_nested_signature_metadata
/usr/bin/sed -i '' 's/CodeDirectory flags=0x10000(runtime)/CodeDirectory flags=0x0(none)/' \
    "$mock_signature_metadata"
expect_nested_failure_before_later_operation
unset QUICKTTY_MOCK_MACHO_PATH

symlink_main_app=$tmp_root/SymlinkMain.app
mkdir -p "$symlink_main_app/Contents/MacOS"
ln -s /usr/bin/true "$symlink_main_app/Contents/MacOS/QuickTTY"
expect_failure sh -c '. "$1"; release_verify_app_code_layout "$2" QuickTTY /usr/bin/file' sh \
    "$helpers" "$symlink_main_app"

printf 'QuickTTY release helper tests passed.\n'
