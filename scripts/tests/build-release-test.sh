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

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P) || fail 'could not resolve test directory'
repo_root=$(CDPATH= cd -P "$script_dir/../.." && pwd -P) || fail 'could not resolve repository root'
helpers=$repo_root/scripts/release-helpers.sh
build_script=$repo_root/scripts/build-release.sh

[ -f "$helpers" ] || fail "release helpers are missing: $helpers"
[ -f "$build_script" ] || fail "release build script is missing: $build_script"

sh -n "$helpers"
sh -n "$build_script"

# These calls stop before tool discovery or any build/signing operation.
expect_failure sh "$build_script" unexpected-option
expect_failure sh "$build_script"
expect_failure env APPLE_ID=unused sh "$build_script"

. "$helpers"

release_validate_label "$RELEASE_LABEL_DEFAULT"
release_validate_team N8FS9YUZQA
release_validate_identity 'Developer ID Application: Dmitriy Lialiuev (N8FS9YUZQA)'
signature_metadata='CodeDirectory v=20500 size=31839 flags=0x10000(runtime) hashes=984+7 location=embedded'
release_signature_has_hardened_runtime "$signature_metadata"
expect_failure sh -c '. "$1"; release_validate_label invalid' sh "$helpers"
expect_failure sh -c '. "$1"; release_validate_team invalid' sh "$helpers"
expect_failure sh -c '. "$1"; release_validate_identity "Apple Development: Example"' sh "$helpers"
expect_failure sh -c '. "$1"; release_signature_has_hardened_runtime "CodeDirectory flags=0x0"' sh "$helpers"
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
            "$tmp_base"/ghostterm-release-test.*) rm -rf "$tmp_root" ;;
            *) printf 'error: refusing to remove unexpected temporary path: %s\n' "$tmp_root" >&2 ;;
        esac
    fi

    exit "$status"
}

trap cleanup 0 HUP INT TERM
tmp_root=$(mktemp -d "$tmp_base/ghostterm-release-test.XXXXXX") || fail 'could not create temporary directory'
case "$tmp_root" in
    "$tmp_base"/ghostterm-release-test.*) ;;
    *) fail "temporary directory has an unexpected path: $tmp_root" ;;
esac

fixture_repo=$tmp_root/repository
mkdir "$fixture_repo"
release_dir=$(release_prepare_output_directory "$fixture_repo")
[ "$release_dir" = "$fixture_repo/.build/Release" ] || fail 'unexpected canonical release directory'

archive_path=$release_dir/$RELEASE_ARCHIVE_NAME
dmg_path=$release_dir/$RELEASE_DMG_NAME
stage_path=$release_dir/$RELEASE_STAGE_NAME
unrelated_path=$release_dir/keep-me.txt
printf 'unrelated\n' >"$unrelated_path"
mkdir "$archive_path" "$stage_path"
printf 'generated\n' >"$dmg_path"

release_remove_generated_directory "$release_dir" "$archive_path"
release_remove_generated_directory "$release_dir" "$stage_path"
release_remove_generated_file "$release_dir" "$dmg_path"
assert_missing "$archive_path"
assert_missing "$stage_path"
assert_missing "$dmg_path"
[ -f "$unrelated_path" ] || fail 'cleanup modified an unrelated release file'

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

printf 'Build release helper tests passed.\n'
