#!/bin/sh
set -eu

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
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
            "$tmp_base"/ghostterm-resources-test.*) rm -rf "$tmp_root" ;;
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

trap cleanup 0 HUP INT TERM
tmp_root=$(mktemp -d "$tmp_base/ghostterm-resources-test.XXXXXX") || fail 'could not create temporary directory'
case "$tmp_root" in
    "$tmp_base"/ghostterm-resources-test.*) ;;
    *) fail "temporary directory has an unexpected path: $tmp_root" ;;
esac

expect_failure sh "$copy_script"
expect_failure sh "$copy_script" /

missing_root=$tmp_root/missing-source-repository
missing_destination=$tmp_root/Missing.app/Contents/Resources
mkdir -p "$missing_root/scripts" "$missing_destination"
cp "$copy_script" "$missing_root/scripts/copy-ghostty-resources.sh"
expect_failure sh "$missing_root/scripts/copy-ghostty-resources.sh" "$missing_destination"

resources="$tmp_root/Fake App.app/Contents/Resources"
mkdir -p "$resources/terminfo" "$resources/ghostty"
printf 'stale terminfo\n' >"$resources/terminfo/stale-file"
printf 'stale ghostty\n' >"$resources/ghostty/stale-file"
printf 'keep\n' >"$resources/keep-file"

sh "$copy_script" "$resources"

[ -f "$resources/terminfo/78/xterm-ghostty" ] || fail 'terminfo sentinel was not copied'
[ -f "$resources/ghostty/shell-integration/bash/ghostty.bash" ] || fail 'shell integration content was not copied'
[ -d "$resources/ghostty/themes" ] || fail 'themes were not copied'
[ ! -e "$resources/terminfo/stale-file" ] || fail 'stale terminfo content was not replaced'
[ ! -e "$resources/ghostty/stale-file" ] || fail 'stale Ghostty content was not replaced'
[ -f "$resources/keep-file" ] || fail 'unrelated resource was modified'
[ ! -e "$resources/locale" ] || fail 'locale files must not be copied'
[ ! -e "$resources/man" ] || fail 'man pages must not be copied'
[ ! -e "$resources/bash-completion" ] || fail 'Bash completions must not be copied'
[ ! -e "$resources/fish" ] || fail 'Fish completions must not be copied'
[ ! -e "$resources/zsh" ] || fail 'Zsh completions must not be copied'

printf 'Ghostty resource copy safety tests passed.\n'
