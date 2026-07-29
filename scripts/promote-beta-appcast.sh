#!/bin/sh
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
export PATH

set -eu

LC_ALL=C
export LC_ALL

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P) || {
    printf 'error: could not resolve script directory\n' >&2
    exit 1
}
repo_root=$(CDPATH= cd -P "$script_dir/.." && pwd -P) || {
    printf 'error: could not resolve repository root\n' >&2
    exit 1
}

# shellcheck source=release-helpers.sh
. "$script_dir/release-helpers.sh"

release_require_no_arguments "$@"
release_reject_secret_environment

[ -e "$repo_root/.git" ] || release_fail "not a Git repository: $repo_root"
source_tree_state=$(release_source_tree_state "$repo_root" /usr/bin/git) \
    || release_fail 'could not determine source tree state'
[ "$source_tree_state" = clean ] \
    || release_fail 'source tree is dirty; refusing to promote beta appcast'

release_dir=$repo_root/.build/Release
source_appcast=$release_dir/$RELEASE_APPCAST_DIRECTORY_NAME/$RELEASE_APPCAST_NAME
final_dmg=$release_dir/$RELEASE_DMG_NAME
target_appcast=$(release_beta_appcast_path "$repo_root")
target_dir=${target_appcast%/*}
expected_target_dir=$repo_root/docs/appcasts

[ "$target_dir" = "$expected_target_dir" ] \
    || release_fail "beta appcast has an unexpected target directory: $target_dir"
[ -d "$target_dir" ] && [ ! -L "$target_dir" ] \
    || release_fail "beta appcast target directory is unsafe: $target_dir"
target_dir_canonical=$(CDPATH= cd -P "$target_dir" && pwd -P) \
    || release_fail "could not resolve beta appcast target directory: $target_dir"
[ "$target_dir_canonical" = "$expected_target_dir" ] \
    || release_fail "beta appcast target directory resolved outside the repository: $target_dir"
[ -f "$target_appcast" ] && [ ! -L "$target_appcast" ] \
    || release_fail "beta appcast target is not a regular file: $target_appcast"

release_verify_appcast "$source_appcast" "$final_dmg" /usr/bin/stat /usr/bin/grep

temporary_appcast=
cleanup() {
    cleanup_status=$?
    trap - 0 HUP INT TERM

    if [ -n "$temporary_appcast" ] && [ -f "$temporary_appcast" ]; then
        /bin/rm -f "$temporary_appcast" || {
            printf 'error: could not remove temporary beta appcast: %s\n' "$temporary_appcast" >&2
        }
    fi

    exit "$cleanup_status"
}

trap cleanup 0 HUP INT TERM
temporary_appcast=$(/usr/bin/mktemp "$target_dir/.QuickTTY-beta-appcast.XXXXXX") \
    || release_fail "could not create temporary beta appcast in: $target_dir"
case "$temporary_appcast" in
    "$target_dir"/.QuickTTY-beta-appcast.*) ;;
    *) release_fail "temporary beta appcast has an unexpected path: $temporary_appcast" ;;
esac
[ -f "$temporary_appcast" ] && [ ! -L "$temporary_appcast" ] \
    || release_fail "temporary beta appcast is unsafe: $temporary_appcast"

/bin/cp "$source_appcast" "$temporary_appcast" \
    || release_fail "could not copy final appcast: $source_appcast"
/bin/mv -f "$temporary_appcast" "$target_appcast" \
    || release_fail "could not promote beta appcast: $target_appcast"
temporary_appcast=
trap - 0 HUP INT TERM

printf 'Promoted beta appcast: %s\n' "$target_appcast"
/usr/bin/grep -F '<enclosure ' "$target_appcast"
