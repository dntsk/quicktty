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
terminfo_replacement_started=0
ghostty_replacement_started=0

cleanup() {
    status=$?
    trap - 0 HUP INT TERM

    if [ "$status" -ne 0 ]; then
        if [ "$ghostty_replacement_started" -eq 1 ]; then
            if resource_exists "$destination/ghostty"; then
                rm -rf "$destination/ghostty"
            fi
            if [ -n "$ghostty_backup" ] && resource_exists "$ghostty_backup"; then
                mv "$ghostty_backup" "$destination/ghostty"
            fi
        fi

        if [ "$terminfo_replacement_started" -eq 1 ]; then
            if resource_exists "$destination/terminfo"; then
                rm -rf "$destination/terminfo"
            fi
            if [ -n "$terminfo_backup" ] && resource_exists "$terminfo_backup"; then
                mv "$terminfo_backup" "$destination/terminfo"
            fi
        fi
    fi

    if [ -n "$stage_dir" ] && [ -d "$stage_dir" ]; then
        rm -rf "$stage_dir"
    fi

    exit "$status"
}

[ "$#" -eq 1 ] || fail 'expected exactly one destination argument'
destination_input=$1

[ -n "$destination_input" ] || fail 'destination must not be empty'
[ "$destination_input" != / ] || fail 'destination must not be /'
case "$destination_input" in
    *.app/Contents/Resources) ;;
    *) fail 'destination must end in .app/Contents/Resources' ;;
esac

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P) || fail 'could not resolve script directory'
repo_root=$(CDPATH= cd -P "$script_dir/.." && pwd -P) || fail 'could not resolve repository root'
source_share=$repo_root/Vendor/ghostty/zig-out/share
terminfo_source=$source_share/terminfo
ghostty_source=$source_share/ghostty

[ -f "$terminfo_source/78/xterm-ghostty" ] || fail "missing Ghostty terminfo sentinel: $terminfo_source/78/xterm-ghostty"
[ -d "$ghostty_source/shell-integration" ] || fail "missing Ghostty shell integration: $ghostty_source/shell-integration"
[ -d "$ghostty_source/themes" ] || fail "missing Ghostty themes: $ghostty_source/themes"

destination_parent_input=$(dirname "$destination_input")
[ -d "$destination_parent_input" ] || fail "destination parent does not exist: $destination_parent_input"
destination_parent=$(CDPATH= cd -P "$destination_parent_input" && pwd -P) || fail 'could not resolve destination parent'
case "$destination_parent" in
    *.app/Contents) ;;
    *) fail 'canonical destination must be inside an .app/Contents directory' ;;
esac

case "$destination_parent" in
    "$repo_root/GhostTerm"|"$repo_root/GhostTerm/"*|"$repo_root/GhostTermTests"|"$repo_root/GhostTermTests/"*|"$repo_root/Vendor"|"$repo_root/Vendor/"*)
        fail 'destination must not be in a repository source directory'
        ;;
esac

destination=$destination_parent/Resources
[ -L "$destination" ] && fail 'destination Resources directory must not be a symlink'
[ -d "$destination" ] || fail "destination does not exist: $destination"

trap cleanup 0 HUP INT TERM

stage_dir=$(mktemp -d "$destination/.ghostty-resources.XXXXXX") || fail 'could not create staging directory'
mkdir "$stage_dir/terminfo" "$stage_dir/ghostty"
cp -pR "$terminfo_source/." "$stage_dir/terminfo/"
cp -pR "$ghostty_source/." "$stage_dir/ghostty/"

[ -f "$stage_dir/terminfo/78/xterm-ghostty" ] || fail 'staged terminfo sentinel is missing'
[ -d "$stage_dir/ghostty/shell-integration" ] || fail 'staged shell integration is missing'
[ -d "$stage_dir/ghostty/themes" ] || fail 'staged themes are missing'

terminfo_replacement_started=1
if resource_exists "$destination/terminfo"; then
    terminfo_backup=$stage_dir/previous-terminfo
    mv "$destination/terminfo" "$terminfo_backup"
fi
mv "$stage_dir/terminfo" "$destination/terminfo"

ghostty_replacement_started=1
if resource_exists "$destination/ghostty"; then
    ghostty_backup=$stage_dir/previous-ghostty
    mv "$destination/ghostty" "$ghostty_backup"
fi
mv "$stage_dir/ghostty" "$destination/ghostty"

rm -rf "$stage_dir"
stage_dir=
