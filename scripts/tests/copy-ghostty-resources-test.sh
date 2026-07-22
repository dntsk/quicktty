#!/bin/sh
set -eu

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

resource_exists() {
    [ -e "$1" ] || [ -L "$1" ]
}

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P) || fail 'could not resolve test directory'
repo_root=$(CDPATH= cd -P "$script_dir/../.." && pwd -P) || fail 'could not resolve repository root'
copy_script=$repo_root/scripts/copy-ghostty-resources.sh

[ -f "$copy_script" ] || fail "copy script is missing: $copy_script"

tmp_base=${TMPDIR:-/tmp}
[ -n "$tmp_base" ] && [ "$tmp_base" != / ] || fail 'temporary directory base must not be empty or /'
tmp_base=$(CDPATH= cd -P "$tmp_base" && pwd -P) || fail "could not resolve temporary directory base: $tmp_base"
tmp_root=

cleanup() {
    status=$?
    trap - 0 HUP INT TERM

    if [ -n "$tmp_root" ] && [ -d "$tmp_root" ]; then
        case "$tmp_root" in
            "$tmp_base"/quicktty-resources-test.*) rm -rf "$tmp_root" ;;
            *) printf 'error: refusing to remove unexpected temporary path: %s\n' "$tmp_root" >&2 ;;
        esac
    fi

    exit "$status"
}

expect_failure() {
    if "$@" >"$tmp_root/command-output" 2>&1; then
        fail "expected command to fail: $*"
    fi
}

create_stale_resources() {
    fixture_resources=$1
    mkdir -p "$fixture_resources/terminfo" "$fixture_resources/ghostty"
    printf 'stale terminfo\n' >"$fixture_resources/terminfo/stale-file"
    printf 'stale ghostty\n' >"$fixture_resources/ghostty/stale-file"
    printf 'keep\n' >"$fixture_resources/keep-file"
}

assert_runtime_resources() {
    fixture_resources=$1

    [ -f "$fixture_resources/terminfo/78/xterm-ghostty" ] || fail 'terminfo sentinel was not copied'
    [ -f "$fixture_resources/ghostty/shell-integration/bash/ghostty.bash" ] || fail 'shell integration content was not copied'
    [ -d "$fixture_resources/ghostty/themes" ] || fail 'themes were not copied'
    [ ! -e "$fixture_resources/terminfo/stale-file" ] || fail 'stale terminfo content was not replaced'
    [ ! -e "$fixture_resources/ghostty/stale-file" ] || fail 'stale Ghostty content was not replaced'
    [ -f "$fixture_resources/keep-file" ] || fail 'unrelated resource was modified'
    [ ! -e "$fixture_resources/locale" ] || fail 'locale files must not be copied'
    [ ! -e "$fixture_resources/man" ] || fail 'man pages must not be copied'
    [ ! -e "$fixture_resources/bash-completion" ] || fail 'Bash completions must not be copied'
    [ ! -e "$fixture_resources/fish" ] || fail 'Fish completions must not be copied'
    [ ! -e "$fixture_resources/zsh" ] || fail 'Zsh completions must not be copied'
}

assert_no_stage_debris() {
    fixture_resources=$1

    for stage in "$fixture_resources"/.ghostty-resources.*; do
        if resource_exists "$stage"; then
            fail "staging directory was not removed: $stage"
        fi
    done
}

copy_for_build_context() {
    build_root=$1
    fixture_resources=$build_root/QuickTTY.app/Contents/Resources

    create_stale_resources "$fixture_resources"
    sh "$copy_script" "$fixture_resources" "$fixture_resources"
    assert_runtime_resources "$fixture_resources"
    assert_no_stage_debris "$fixture_resources"
}

trap cleanup 0 HUP INT TERM
tmp_root=$(mktemp -d "$tmp_base/quicktty-resources-test.XXXXXX") || fail 'could not create temporary directory'
case "$tmp_root" in
    "$tmp_base"/quicktty-resources-test.*) ;;
    *) fail "temporary directory has an unexpected path: $tmp_root" ;;
esac

expect_failure sh "$copy_script"
expect_failure sh "$copy_script" /
expect_failure sh "$copy_script" "$tmp_root/Other.app/Contents/Resources" "$tmp_root/Other.app/Contents/Resources"
expect_failure sh "$copy_script" /Applications/QuickTTY.app /Applications/QuickTTY.app

missing_root=$tmp_root/missing-source-repository
missing_destination=$missing_root/build/QuickTTY.app/Contents/Resources
mkdir -p "$missing_root/scripts" "$missing_destination"
cp "$copy_script" "$missing_root/scripts/copy-ghostty-resources.sh"
expect_failure sh "$missing_root/scripts/copy-ghostty-resources.sh" "$missing_destination" "$missing_destination"

mismatched_resources=$tmp_root/Mismatched/Build/Products/Debug/QuickTTY.app/Contents/Resources
other_expected_resources=$tmp_root/Mismatched/Build/Products/Release/QuickTTY.app/Contents/Resources
mkdir -p "$mismatched_resources" "$other_expected_resources"
expect_failure sh "$copy_script" "$mismatched_resources" "$other_expected_resources"

linked_resources=$tmp_root/LinkedResources/Build/Products/Debug/QuickTTY.app/Contents/Resources
linked_target=$tmp_root/linked-resources-target
mkdir -p "$(dirname "$linked_resources")" "$linked_target"
ln -s "$linked_target" "$linked_resources"
expect_failure sh "$copy_script" "$linked_resources" "$linked_resources"

copy_for_build_context "$tmp_root/repository/.build/DerivedData/Build/Products/Debug"
copy_for_build_context "$tmp_root/Library/Developer/Xcode/DerivedData/QuickTTY-test/Build/Products/Debug"
copy_for_build_context "$tmp_root/archives/QuickTTY.xcarchive/Products/Applications"

symlink_resources=$tmp_root/SymlinkTargets/Build/Products/Debug/QuickTTY.app/Contents/Resources
symlink_target=$tmp_root/symlink-target
mkdir -p "$symlink_resources" "$symlink_target/terminfo" "$symlink_target/ghostty"
printf 'outside terminfo\n' >"$symlink_target/terminfo/keep-file"
printf 'outside ghostty\n' >"$symlink_target/ghostty/keep-file"
printf 'keep\n' >"$symlink_resources/keep-file"
ln -s "$symlink_target/terminfo" "$symlink_resources/terminfo"
ln -s "$symlink_target/ghostty" "$symlink_resources/ghostty"
sh "$copy_script" "$symlink_resources" "$symlink_resources"
assert_runtime_resources "$symlink_resources"
assert_no_stage_debris "$symlink_resources"
[ ! -L "$symlink_resources/terminfo" ] || fail 'terminfo symlink was not replaced'
[ ! -L "$symlink_resources/ghostty" ] || fail 'Ghostty symlink was not replaced'
[ -f "$symlink_target/terminfo/keep-file" ] || fail 'terminfo symlink target was modified'
[ -f "$symlink_target/ghostty/keep-file" ] || fail 'Ghostty symlink target was modified'

signal_resources=$tmp_root/Signal/Build/Products/Debug/QuickTTY.app/Contents/Resources
create_stale_resources "$signal_resources"
signal_status=0
QUICKTTY_TEST_SEND_TERM_AFTER_TERMINFO_BACKUP=1 \
    sh "$copy_script" "$signal_resources" "$signal_resources" >"$tmp_root/signal-output" 2>&1 || signal_status=$?
[ "$signal_status" -ne 0 ] || fail 'TERM failpoint unexpectedly succeeded'
[ -f "$signal_resources/terminfo/stale-file" ] || fail 'TERM did not restore terminfo'
[ -f "$signal_resources/ghostty/stale-file" ] || fail 'TERM modified Ghostty before its replacement'
[ ! -e "$signal_resources/terminfo/78/xterm-ghostty" ] || fail 'TERM left staged terminfo in place'
assert_no_stage_debris "$signal_resources"

printf 'Ghostty resource copy safety tests passed.\n'
