#!/bin/sh
set -eu

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

expect_failure() {
    if "$@" >"$test_root/rejected.stdout" 2>"$test_root/rejected.stderr"; then
        fail "command unexpectedly succeeded: $*"
    fi
}

cleanup() {
    case "${test_root:-}" in
        "${TMPDIR:-/tmp}"/quicktty-copy-cli-test.*)
            [ ! -L "$test_root" ] && [ -d "$test_root" ] && /bin/rm -rf "$test_root"
            ;;
        "") ;;
        *) printf 'FAIL: refusing to remove unexpected test path: %s\n' "$test_root" >&2 ;;
    esac
}

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
repo_root=$(CDPATH= cd -P "$script_dir/../.." && pwd -P)
copy_script=$repo_root/scripts/copy-cli-helper.sh
copier_source=$repo_root/scripts/CopyCLIHelper.swift

[ -f "$copy_script" ] || fail "copy script is missing: $copy_script"
[ -x "$copy_script" ] || fail "copy script is not executable: $copy_script"
[ -f "$copier_source" ] || fail "Swift copier source is missing: $copier_source"
/bin/sh -n "$copy_script"
/usr/bin/xcrun --sdk macosx swiftc -typecheck "$copier_source"

test_root=$(mktemp -d "${TMPDIR:-/tmp}/quicktty-copy-cli-test.XXXXXX")
case "$test_root" in
    "${TMPDIR:-/tmp}"/quicktty-copy-cli-test.*) ;;
    *) fail "temporary root has an unexpected path: $test_root" ;;
esac
trap cleanup 0 HUP INT TERM

test_copier=$test_root/copy-cli-helper-test
/usr/bin/xcrun --sdk macosx swiftc \
    -D QUICKTTY_COPY_CLI_HELPER_TESTING \
    "$copier_source" \
    -o "$test_copier"

source_dir=$test_root/products
contents=$test_root/build/QuickTTY.app/Contents
destination=$contents/Helpers/quicktty
assert_exact_helper_layout() {
    [ -f "$destination" ] && [ ! -L "$destination" ] \
        || fail 'copied helper is not a regular file'
    [ "$(/usr/bin/stat -f '%Lp' "$destination")" = 755 ] \
        || fail 'copied helper mode is not 0755'
    [ "$(/usr/bin/find "$contents/Helpers" -mindepth 1 -maxdepth 1 -print \
        | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 1 ] \
        || fail 'Helpers must contain exactly one entry'
    [ "$(/usr/bin/find "$contents/Helpers" -mindepth 1 -maxdepth 1 -print)" = "$destination" ] \
        || fail 'Helpers contains an entry other than exact quicktty'
}
/bin/mkdir -p "$source_dir" "$contents"
source_executable=$source_dir/quicktty
printf '#!/bin/sh\nprintf first\\n\n' >"$source_executable"
/bin/chmod 700 "$source_executable"
printf 'unrelated sentinel\n' >"$test_root/unrelated"
/bin/chmod 640 "$test_root/unrelated"

"$copy_script" "$source_executable" "$destination"
assert_exact_helper_layout
[ -x "$destination" ] || fail 'copied helper is not executable'
/usr/bin/cmp -s "$source_executable" "$destination" || fail 'copied helper content differs'
[ "$(cat "$test_root/unrelated")" = 'unrelated sentinel' ] || fail 'unrelated file changed'
[ "$(/usr/bin/stat -f '%Lp' "$test_root/unrelated")" = 640 ] || fail 'unrelated mode changed'

printf '#!/bin/sh\nprintf second\\n\n' >"$source_executable"
/bin/chmod 755 "$source_executable"
"$copy_script" "$source_executable" "$destination"
assert_exact_helper_layout
/usr/bin/cmp -s "$source_executable" "$destination" || fail 'idempotent replacement failed'
[ -z "$(find "$contents/Helpers" -maxdepth 1 -name '.quicktty-copy.*' -print)" ] \
    || fail 'copy left a staging file'
[ "$(cat "$test_root/unrelated")" = 'unrelated sentinel' ] || fail 'replacement changed unrelated file'

preserved_destination=$test_root/preserved-destination
/bin/cp "$destination" "$preserved_destination"
growing_source=$source_dir/growing-source
printf '#!/bin/sh\nprintf growing\\n\n' >"$growing_source"
/bin/chmod 755 "$growing_source"
source_size_before_growth=$(/usr/bin/stat -f '%z' "$growing_source")
expect_failure /usr/bin/env QUICKTTY_COPY_CLI_HELPER_APPEND_AFTER_FSTAT=1 \
    "$test_copier" "$growing_source" "$destination"
[ "$(/usr/bin/stat -f '%z' "$growing_source")" = "$((source_size_before_growth + 1))" ] \
    || fail 'growth failpoint did not append exactly one byte'
/usr/bin/cmp -s "$preserved_destination" "$destination" \
    || fail 'source growth replaced destination'
[ -z "$(find "$contents/Helpers" -maxdepth 1 -name '.quicktty-copy.*' -print)" ] \
    || fail 'source growth left a staging file'

nonexecutable=$source_dir/nonexecutable
printf 'not executable\n' >"$nonexecutable"
/bin/chmod 600 "$nonexecutable"
expect_failure "$copy_script" "$nonexecutable" "$destination"

source_link=$source_dir/source-link
/bin/ln -s "$source_executable" "$source_link"
expect_failure "$copy_script" "$source_link" "$destination"

expect_failure "$copy_script" "$source_dir" "$destination"
expect_failure "$copy_script" "$source_executable" "$test_root/build/Other.app/Contents/Helpers/quicktty"
expect_failure "$copy_script" "$source_executable" "$contents/Helpers/not-quicktty"

/bin/rm -f "$destination"
/bin/mkdir "$destination"
expect_failure "$copy_script" "$source_executable" "$destination"
[ -d "$destination" ] || fail 'destination directory changed after rejection'
/bin/rmdir "$destination"

/bin/ln -s "$test_root/unrelated" "$destination"
expect_failure "$copy_script" "$source_executable" "$destination"
[ "$(cat "$test_root/unrelated")" = 'unrelated sentinel' ] || fail 'destination symlink target changed'
/bin/rm -f "$destination"

linked_contents=$test_root/linked/QuickTTY.app/Contents
real_helpers=$test_root/real-helpers
/bin/mkdir -p "$linked_contents" "$real_helpers"
/bin/ln -s "$real_helpers" "$linked_contents/Helpers"
expect_failure "$copy_script" "$source_executable" "$linked_contents/Helpers/quicktty"

contents_link_root=$test_root/contents-link/QuickTTY.app
real_contents=$test_root/real/QuickTTY.app/Contents
/bin/mkdir -p "$contents_link_root" "$real_contents"
/bin/ln -s "$real_contents" "$contents_link_root/Contents"
expect_failure "$copy_script" "$source_executable" "$contents_link_root/Contents/Helpers/quicktty"

[ -z "$(find "$test_root" -name '.quicktty-copy.*' -print)" ] \
    || fail 'rejected copy left a staging file'
[ "$(cat "$test_root/unrelated")" = 'unrelated sentinel' ] || fail 'rejected copies changed unrelated file'
printf 'copy-cli-helper contract tests passed.\n'
