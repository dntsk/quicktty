#!/bin/sh
set -eu

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

resource_exists() {
    [ -e "$1" ] || [ -L "$1" ]
}

stage_dir=
terminfo_backup=
ghostty_backup=
terminfo_had_original=0
ghostty_had_original=0
terminfo_replacement_started=0
ghostty_replacement_started=0

rollback_terminfo() {
    [ "$terminfo_replacement_started" -eq 1 ] || return 0

    if [ "$terminfo_had_original" -eq 1 ] && ! resource_exists "$terminfo_backup"; then
        return 0
    fi

    if resource_exists terminfo; then
        rm -rf terminfo || return 1
    fi
    if [ -n "$terminfo_backup" ] && resource_exists "$terminfo_backup"; then
        mv "$terminfo_backup" terminfo || return 1
    fi
}

rollback_ghostty() {
    [ "$ghostty_replacement_started" -eq 1 ] || return 0

    if [ "$ghostty_had_original" -eq 1 ] && ! resource_exists "$ghostty_backup"; then
        return 0
    fi

    if resource_exists ghostty; then
        rm -rf ghostty || return 1
    fi
    if [ -n "$ghostty_backup" ] && resource_exists "$ghostty_backup"; then
        mv "$ghostty_backup" ghostty || return 1
    fi
}

rollback() {
    rollback_status=0

    rollback_ghostty || rollback_status=1
    rollback_terminfo || rollback_status=1

    return "$rollback_status"
}

remove_stage() {
    if [ -n "$stage_dir" ] && [ -d "$stage_dir" ]; then
        rm -rf "$stage_dir"
    fi
    stage_dir=
}

cleanup_exit() {
    status=$?
    trap - 0 HUP INT TERM

    if [ "$status" -ne 0 ]; then
        rollback || printf 'error: could not fully restore Ghostty resources\n' >&2
    fi
    remove_stage || printf 'error: could not remove Ghostty resource staging directory\n' >&2

    exit "$status"
}

handle_signal() {
    signal_status=$1
    trap - 0 HUP INT TERM

    rollback || printf 'error: could not fully restore Ghostty resources\n' >&2
    remove_stage || printf 'error: could not remove Ghostty resource staging directory\n' >&2

    exit "$signal_status"
}

[ "$#" -eq 2 ] || fail 'expected destination and expected Xcode resource path arguments'
destination_input=$1
expected_resources_input=$2

[ -n "$destination_input" ] || fail 'destination must not be empty'
[ -n "$expected_resources_input" ] || fail 'expected Xcode resource path must not be empty'
case "$destination_input" in
    */GhostTerm.app/Contents/Resources) ;;
    *) fail 'destination must end in GhostTerm.app/Contents/Resources' ;;
esac
case "$expected_resources_input" in
    */GhostTerm.app/Contents/Resources) ;;
    *) fail 'expected Xcode resource path must end in GhostTerm.app/Contents/Resources' ;;
esac

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P) || fail 'could not resolve script directory'
repo_root=$(CDPATH= cd -P "$script_dir/.." && pwd -P) || fail 'could not resolve repository root'
source_share=$repo_root/Vendor/ghostty/zig-out/share
terminfo_source=$source_share/terminfo
ghostty_source=$source_share/ghostty

[ -f "$terminfo_source/78/xterm-ghostty" ] || fail "missing Ghostty terminfo sentinel: $terminfo_source/78/xterm-ghostty"
[ -d "$ghostty_source/shell-integration" ] || fail "missing Ghostty shell integration: $ghostty_source/shell-integration"
[ -d "$ghostty_source/themes" ] || fail "missing Ghostty themes: $ghostty_source/themes"

[ -L "$destination_input" ] && fail 'destination Resources directory must not be a symlink'
[ -d "$destination_input" ] || fail "destination does not exist: $destination_input"
CDPATH= cd -P "$destination_input" || fail 'could not enter destination Resources directory'
destination=$(pwd -P)
case "$destination" in
    */GhostTerm.app/Contents/Resources) ;;
    *) fail 'canonical destination must end in GhostTerm.app/Contents/Resources' ;;
esac

[ -L "$expected_resources_input" ] && fail 'expected Xcode Resources directory must not be a symlink'
[ -d "$expected_resources_input" ] || fail "expected Xcode Resources directory does not exist: $expected_resources_input"
expected_resources=$(CDPATH= cd -P "$expected_resources_input" && pwd -P) || fail 'could not resolve expected Xcode Resources directory'
# This equality check prevents accidental direct calls from targeting another app; arguments are not a security boundary.
[ "$destination" = "$expected_resources" ] || fail 'destination does not match the expected Xcode resource path'

trap cleanup_exit 0
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

stage_dir=$(mktemp -d .ghostty-resources.XXXXXX) || fail 'could not create staging directory'
case "$stage_dir" in
    .ghostty-resources.*) ;;
    *) fail "staging directory has an unexpected path: $stage_dir" ;;
esac
mkdir "$stage_dir/terminfo" "$stage_dir/ghostty"
cp -pR "$terminfo_source/." "$stage_dir/terminfo/"
cp -pR "$ghostty_source/." "$stage_dir/ghostty/"

[ -f "$stage_dir/terminfo/78/xterm-ghostty" ] || fail 'staged terminfo sentinel is missing'
[ -d "$stage_dir/ghostty/shell-integration" ] || fail 'staged shell integration is missing'
[ -d "$stage_dir/ghostty/themes" ] || fail 'staged themes are missing'

if resource_exists terminfo; then
    terminfo_backup=$stage_dir/previous-terminfo
    terminfo_had_original=1
    terminfo_replacement_started=1
    mv terminfo "$terminfo_backup"
else
    terminfo_replacement_started=1
fi

# This test-only failpoint exercises rollback after the original target is safely staged.
if [ "$terminfo_had_original" -eq 1 ] && [ "${GHOSTTERM_TEST_SEND_TERM_AFTER_TERMINFO_BACKUP:-}" = 1 ]; then
    kill -TERM "$$"
fi

mv "$stage_dir/terminfo" terminfo

if resource_exists ghostty; then
    ghostty_backup=$stage_dir/previous-ghostty
    ghostty_had_original=1
    ghostty_replacement_started=1
    mv ghostty "$ghostty_backup"
else
    ghostty_replacement_started=1
fi
mv "$stage_dir/ghostty" ghostty

remove_stage
