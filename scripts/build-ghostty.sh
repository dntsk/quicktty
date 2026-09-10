#!/bin/sh
set -eu

DEFAULT_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
REQUIRED_GHOSTTY_COMMIT=332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28
REQUIRED_ZIG_VERSION=0.15.2
QUICKTTY_FORCE_GHOSTTY_REBUILD=${QUICKTTY_FORCE_GHOSTTY_REBUILD:-0}

case "$QUICKTTY_FORCE_GHOSTTY_REBUILD" in
    0 | 1) ;;
    *)
        printf '%s\n' 'error: QUICKTTY_FORCE_GHOSTTY_REBUILD must be unset, 0, or 1' >&2
        exit 1
        ;;
esac

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "$DEFAULT_DEVELOPER_DIR" ]; then
    DEVELOPER_DIR=$DEFAULT_DEVELOPER_DIR
    export DEVELOPER_DIR
fi

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

# Check every boundary, not just the leaf, before touching generated paths.
# Return errors rather than exiting so rollback can still restore the other output.
safe_path() {
    case "$1" in
        "$repo_root"/*) ;;
        *) printf 'error: path is outside the repository: %s\n' "$1" >&2; return 1 ;;
    esac
    case "$1/" in
        */../* | */./*) printf 'error: path contains traversal: %s\n' "$1" >&2; return 1 ;;
    esac
    safe_component=$1
    while [ "$safe_component" != "$repo_root" ]; do
        if [ -L "$safe_component" ]; then
            printf 'error: refusing generated path through symlink: %s\n' "$safe_component" >&2
            return 1
        fi
        safe_component=${safe_component%/*}
    done
}

safe_directory() {
    safe_path "$1" || return 1
    if [ -e "$1" ] && [ ! -d "$1" ]; then
        printf 'error: generated directory path is not a directory: %s\n' "$1" >&2
        return 1
    fi
}

validate_share() {
    safe_directory "$1" || return 1
    safe_directory "$1/terminfo/78" || return 1
    safe_directory "$1/ghostty/shell-integration" || return 1
    safe_directory "$1/ghostty/themes" || return 1
    [ -f "$1/terminfo/78/xterm-ghostty" ] &&
        [ -d "$1/ghostty/shell-integration" ] &&
        [ -d "$1/ghostty/themes" ]
}

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
repo_root=$(CDPATH= cd -P "$script_dir/.." && pwd -P)
ghostty_dir=$repo_root/Vendor/ghostty
published_xcframework_dir=$ghostty_dir/macos/GhosttyKit.xcframework
published_share_dir=$ghostty_dir/zig-out/share
xcframework_dir=$published_xcframework_dir
cache_dir=$repo_root/.build/ghostty
# Order is part of the build identity; do not replace this with a glob.
patch_names='0001-free-text-abi.patch 0002-screen-point-bounds.patch 0003-darwin-process-exit-status.patch 0004-managed-terminal-control.patch'
patch_dir=$script_dir/patches/ghostty

# Fixed, whitespace-free paths only; validation and application share this list.
patch_targets() {
    case "$1" in
        0001-free-text-abi.patch | 0002-screen-point-bounds.patch)
            printf '%s\n' 'src/apprt/embedded.zig' ;;
        0003-darwin-process-exit-status.patch)
            printf '%s\n' 'src/termio/Exec.zig' ;;
        0004-managed-terminal-control.patch)
            printf '%s\n' 'include/ghostty.h src/apprt/embedded.zig src/Surface.zig src/termio/Exec.zig src/termio/Termio.zig' ;;
        *) fail "unapproved Ghostty patch: $1" ;;
    esac
}

case "$repo_root" in
    *[[:space:]]*) fail "repository path contains whitespace unsupported by zig ar MRI commands: $repo_root" ;;
esac

command -v git >/dev/null 2>&1 || fail "required command not found: git"
command -v zig >/dev/null 2>&1 || fail "required command not found: zig"
command -v xcodebuild >/dev/null 2>&1 || fail "required command not found: xcodebuild"
command -v nm >/dev/null 2>&1 || fail "required command not found: nm"
command -v ar >/dev/null 2>&1 || fail "required command not found: ar"
command -v ranlib >/dev/null 2>&1 || fail "required command not found: ranlib"
command -v mktemp >/dev/null 2>&1 || fail "required command not found: mktemp"
command -v grep >/dev/null 2>&1 || fail "required command not found: grep"
command -v awk >/dev/null 2>&1 || fail "required command not found: awk"
command -v shasum >/dev/null 2>&1 || fail "required command not found: shasum"
for tool in tar cp mkdir mv rm rmdir uname stat; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command not found: $tool"
done
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] \
    || fail 'native GhosttyKit builds require a macOS arm64 host'

safe_directory "$cache_dir" || fail 'unsafe Ghostty build cache path'
safe_directory "$published_xcframework_dir" || fail 'unsafe GhosttyKit publication path'
safe_directory "$published_share_dir" || fail 'unsafe Ghostty resource publication path'

archive_exports_symbol() {
    symbol_archive_path=$1
    required_symbol=$2
    nm -gU "$symbol_archive_path" 2>/dev/null | grep -Eq "[[:space:]]${required_symbol}\$"
}

archive_has_required_symbols() {
    required_symbols_archive_path=$1

    for required_symbol in \
        _ghostty_init \
        _ghostty_app_new \
        _ghostty_config_new \
        _ghostty_surface_new \
        _quicktty_surface_new_managed \
        _quicktty_surface_output_state \
        _quicktty_surface_read_tail \
        _FT_New_Library \
        _ImFontConfig_ImFontConfig \
        _glslang_initialize_process \
        _sentry_malloc \
        _mpack_start_array \
        _zig_os_log_with_type
    do
        archive_exports_symbol "$required_symbols_archive_path" "$required_symbol" || return 1
    done
}

manifest_contains_archive() {
    manifest_check_path=$1
    manifest_expected_archive=$2

    awk -v expected="$manifest_expected_archive" '
        NF > 0 && $NF == expected { found = 1 }
        END { exit !found }
    ' "$manifest_check_path"
}

validate_manifest_inputs() {
    manifest_input_path=$1
    manifest_inputs_output_path=$2

    awk 'NF > 0 && $NF ~ /[.]a$/ { print $NF }' "$manifest_input_path" >"$manifest_inputs_output_path" \
        || fail "could not parse Zig cache manifest: $manifest_input_path"

    manifest_archive_count=0
    while IFS= read -r archive_relative || [ -n "$archive_relative" ]; do
        case "$archive_relative" in
            .zig-cache/o/*) ;;
            *) fail "manifest archive input is not a relative path under .zig-cache/o/: $archive_relative" ;;
        esac
        case "/$archive_relative/" in
            */../* | */./*) fail "manifest archive input contains a traversal component: $archive_relative" ;;
        esac

        archive_absolute=$source_dir/$archive_relative
        safe_path "$archive_absolute" || fail "unsafe manifest archive input: $archive_absolute"
        [ -f "$archive_absolute" ] || fail "manifest archive input is not a regular file: $archive_absolute"
        ar -t "$archive_absolute" >/dev/null 2>&1 || fail "manifest input is not a valid archive: $archive_absolute"
        manifest_archive_count=$((manifest_archive_count + 1))
    done <"$manifest_inputs_output_path"
}

locate_fat_archive() {
    fat_archive=
    fat_archive_count=0

    for fat_archive_candidate in "$xcframework_dir"/*/libghostty-fat.a; do
        [ -f "$fat_archive_candidate" ] || continue
        safe_path "$fat_archive_candidate" || return 1
        fat_archive=$fat_archive_candidate
        fat_archive_count=$((fat_archive_count + 1))
    done

    [ "$fat_archive_count" -eq 1 ]
}

archive_sha256() {
    checksum_archive_path=$1
    checksum_output=$(shasum -a 256 "$checksum_archive_path") || return 1
    checksum_value=${checksum_output%% *}
    printf '%s\n' "$checksum_value"
}

validate_cached_xcframework() {
    cache_validation_error=

    if [ ! -f "$stamp_path" ]; then
        cache_validation_error="cache stamp is missing"
        return 1
    fi

    {
        if ! IFS= read -r stamp_cache_key_line; then
            cache_validation_error="cache stamp is missing the cache-key field"
            return 1
        fi
        if ! IFS= read -r stamp_archive_checksum_line; then
            cache_validation_error="cache stamp is missing the archive-sha256 field"
            return 1
        fi
        if IFS= read -r unexpected_stamp_line; then
            cache_validation_error="cache stamp has unexpected extra content"
            return 1
        fi
    } <"$stamp_path"

    case "$stamp_cache_key_line" in
        cache-key=*) stamp_cache_key=${stamp_cache_key_line#cache-key=} ;;
        *)
            cache_validation_error="cache stamp has an invalid cache-key field"
            return 1
            ;;
    esac
    case "$stamp_archive_checksum_line" in
        archive-sha256=*) stamp_archive_checksum=${stamp_archive_checksum_line#archive-sha256=} ;;
        *)
            cache_validation_error="cache stamp has an invalid archive-sha256 field"
            return 1
            ;;
    esac

    [ "$stamp_cache_key" = "$cache_key" ] || {
        cache_validation_error="cache stamp key does not match the current cache key"
        return 1
    }
    printf '%s\n' "$stamp_archive_checksum" | grep -Eq '^[0-9a-f]{64}$' || {
        cache_validation_error="cache stamp archive checksum is malformed"
        return 1
    }
    [ -d "$xcframework_dir" ] || {
        cache_validation_error="cached XCFramework is missing"
        return 1
    }
    locate_fat_archive || {
        cache_validation_error="cached XCFramework must contain exactly one libghostty-fat.a; found $fat_archive_count"
        return 1
    }

    actual_archive_checksum=$(archive_sha256 "$fat_archive") || {
        cache_validation_error="could not checksum cached Ghostty archive"
        return 1
    }
    [ "$actual_archive_checksum" = "$stamp_archive_checksum" ] || {
        cache_validation_error="cached Ghostty archive checksum does not match the stamp"
        return 1
    }
    archive_has_required_symbols "$fat_archive" || {
        cache_validation_error="cached Ghostty archive failed representative symbol validation"
        return 1
    }
    validate_share "$published_share_dir" || {
        cache_validation_error="cached Ghostty share resources are missing or unsafe"
        return 1
    }
}

stage_dir=
lock_dir=$cache_dir/build.lock
lock_owned=0
publish_complete=0
cache_reused=0
xcframework_had_original=0
share_had_original=0
xcframework_replacement_started=0
share_replacement_started=0
stamp_had_original=0
stamp_replacement_started=0

rollback_stamp() {
    [ "$stamp_replacement_started" -eq 1 ] || return 0
    safe_path "$stamp_path" || return 1
    safe_path "$stage_dir/previous.stamp" || return 1
    if [ -e "$stamp_path" ] && [ ! -f "$stamp_path" ]; then
        printf 'error: refusing to restore stamp over non-file: %s\n' "$stamp_path" >&2
        return 1
    fi
    printf 'Restoring Ghostty cache stamp: %s (backup: %s)\n' \
        "$stamp_path" "$stage_dir/previous.stamp" >&2
    if [ "$stamp_had_original" -eq 1 ]; then
        [ -f "$stage_dir/previous.stamp" ] || return 1
        mv -f "$stage_dir/previous.stamp" "$stamp_path" || return 1
    else
        rm -f "$stamp_path" || return 1
    fi
}

rollback_xcframework() {
    [ "$xcframework_replacement_started" -eq 1 ] || return 0
    safe_directory "$stage_dir/previous-xcframework" || return 1
    safe_directory "$published_xcframework_dir" || return 1
    # A failed backup rename leaves the original in place, so do not remove it.
    if [ "$xcframework_had_original" -eq 1 ] && [ ! -d "$stage_dir/previous-xcframework" ]; then
        return 0
    fi
    printf 'Restoring GhosttyKit output: %s (backup: %s)\n' \
        "$published_xcframework_dir" "$stage_dir/previous-xcframework" >&2
    if [ -e "$published_xcframework_dir" ]; then
        rm -rf "$published_xcframework_dir" || return 1
    fi
    if [ "$xcframework_had_original" -eq 1 ]; then
        mv "$stage_dir/previous-xcframework" "$published_xcframework_dir" || return 1
    fi
}

rollback_share() {
    [ "$share_replacement_started" -eq 1 ] || return 0
    safe_directory "$stage_dir/previous-share" || return 1
    safe_directory "$published_share_dir" || return 1
    if [ "$share_had_original" -eq 1 ] && [ ! -d "$stage_dir/previous-share" ]; then
        return 0
    fi
    printf 'Restoring Ghostty share output: %s (backup: %s)\n' \
        "$published_share_dir" "$stage_dir/previous-share" >&2
    if [ -e "$published_share_dir" ]; then
        rm -rf "$published_share_dir" || return 1
    fi
    if [ "$share_had_original" -eq 1 ]; then
        mv "$stage_dir/previous-share" "$published_share_dir" || return 1
    fi
}

cleanup() {
    cleanup_result=0
    if [ "$publish_complete" -eq 0 ]; then
        rollback_stamp || cleanup_result=1
        rollback_share || cleanup_result=1
        rollback_xcframework || cleanup_result=1
    fi
    if [ -n "$stage_dir" ]; then
        if [ "$cleanup_result" -eq 0 ] && { [ "$publish_complete" -eq 1 ] || [ "$cache_reused" -eq 1 ]; }; then
            printf 'Removing owned Ghostty source/repack/backup stage: %s\n' "$stage_dir" >&2
            if safe_directory "$stage_dir"; then
                rm -rf "$stage_dir" || cleanup_result=1
            else
                cleanup_result=1
            fi
        else
            # Keep failed sources, logs, and any unrestored backups for diagnosis.
            printf 'Retained Ghostty build stage: %s\n' "$stage_dir" >&2
        fi
    fi
    if [ "$lock_owned" -eq 1 ]; then
        if safe_directory "$lock_dir"; then
            printf 'Removing owned Ghostty build lock: %s\n' "$lock_dir" >&2
            rmdir "$lock_dir" || cleanup_result=1
        else
            cleanup_result=1
        fi
    fi
    return "$cleanup_result"
}

cleanup_exit() {
    cleanup_status=$?
    trap - EXIT HUP INT TERM
    cleanup || printf '%s\n' 'error: could not fully restore or clean up Ghostty build files' >&2
    exit "$cleanup_status"
}

handle_signal() {
    signal_status=$1
    trap - EXIT HUP INT TERM
    cleanup || printf '%s\n' 'error: could not fully restore or clean up Ghostty build files' >&2
    exit "$signal_status"
}

[ -f "$ghostty_dir/.git" ] || fail "Ghostty submodule is not initialized; run 'git submodule update --init --recursive'"
actual_commit=$(git -C "$ghostty_dir" rev-parse HEAD 2>/dev/null) || fail "could not determine Ghostty submodule revision"
[ "$actual_commit" = "$REQUIRED_GHOSTTY_COMMIT" ] || fail "Ghostty must be checked out at $REQUIRED_GHOSTTY_COMMIT; found $actual_commit"

index_commit=$(git -C "$repo_root" rev-parse ':Vendor/ghostty' 2>/dev/null) || fail "Ghostty gitlink is missing from the superproject index"
[ "$index_commit" = "$REQUIRED_GHOSTTY_COMMIT" ] || fail "Ghostty gitlink must reference $REQUIRED_GHOSTTY_COMMIT; found $index_commit"

dirty_status=$(git -C "$ghostty_dir" status --porcelain --untracked-files=all) || fail "could not inspect Ghostty submodule status"
if [ -n "$dirty_status" ]; then
    printf 'error: Ghostty submodule has modified, staged, or untracked non-ignored files:\n%s\n' "$dirty_status" >&2
    exit 1
fi

zig_version=$(zig version 2>&1) || fail "could not determine Zig version"
[ "$zig_version" = "$REQUIRED_ZIG_VERSION" ] || fail "Zig $REQUIRED_ZIG_VERSION is required; found $zig_version"

xcode_version_output=$(xcodebuild -version 2>&1) || fail "could not determine Xcode version"
xcode_build_version=$(
    printf '%s\n' "$xcode_version_output" | while IFS=' ' read -r label kind value extra; do
        if [ "$label" = "Build" ] && [ "$kind" = "version" ] && [ -n "$value" ] && [ -z "$extra" ]; then
            printf '%s\n' "$value"
            break
        fi
    done
)
[ -n "$xcode_build_version" ] || fail "could not determine Xcode build version"

set -- \
    -Dapp-runtime=none \
    -Dxcframework-target=native \
    -Demit-xcframework=true \
    -Demit-macos-app=false \
    -Doptimize=ReleaseFast \
    -Dversion-string=1.3.1

# Version discovery inside .build would otherwise find the superproject's Git metadata.
# A fresh source stage also avoids deleting or reusing the user's Vendor Zig cache.
mkdir -p "$cache_dir"
safe_directory "$lock_dir" || fail 'unsafe Ghostty build lock path'
trap cleanup_exit EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM
mkdir "$lock_dir" || fail "Ghostty build lock already exists or cannot be created: $lock_dir"
lock_owned=1

stage_dir=$(mktemp -d "$cache_dir/source-stage.XXXXXX") || fail 'could not create Ghostty source stage'
case "${stage_dir#"$cache_dir"/}" in
    */* | '') fail "unexpected Ghostty stage path: $stage_dir" ;;
    source-stage.*) ;;
    *) fail "unexpected Ghostty stage path: $stage_dir" ;;
esac
safe_directory "$stage_dir" || fail 'unsafe Ghostty source stage'
source_dir=$stage_dir/source
source_relative=${source_dir#"$repo_root"/}
mkdir "$source_dir" "$stage_dir/patches"
printf 'Ghostty source stage: %s\n' "$source_dir"

patch_manifest_path=$stage_dir/patches.manifest
: >"$patch_manifest_path"
for patch_name in $patch_names; do
    patch_path=$patch_dir/$patch_name
    safe_path "$patch_path" || fail "unsafe Ghostty patch path: $patch_path"
    [ -f "$patch_path" ] && [ -s "$patch_path" ] || fail "missing or empty Ghostty patch: $patch_path"
    patch_snapshot=$stage_dir/patches/$patch_name
    cp "$patch_path" "$patch_snapshot" || fail "could not stage Ghostty patch: $patch_path"
    patch_checksum=$(archive_sha256 "$patch_snapshot") || fail "could not checksum Ghostty patch: $patch_path"
    printf 'patch=scripts/patches/ghostty/%s\npatch-sha256=%s\n' \
        "$patch_name" "$patch_checksum" >>"$patch_manifest_path" || fail 'could not record Ghostty patch identity'
    patch_target_paths=$(patch_targets "$patch_name") || fail "could not resolve Ghostty patch targets: $patch_name"
    patch_stat=$(git -C "$repo_root" apply --numstat "$patch_snapshot") || fail "malformed Ghostty patch: $patch_path"
    printf '%s\n' "$patch_stat" | awk -F '\t' -v targets="$patch_target_paths" '
        BEGIN {
            count = split(targets, expected, " ")
            for (i = 1; i <= count; i++) {
                if (expected[i] == "" || expected[i] in allowed) bad = 1
                allowed[expected[i]] = 1
            }
        }
        {
            if (NF != 3 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ ||
                !($3 in allowed)) bad = 1
            if (++seen[$3] != 1) bad = 1
        }
        END {
            for (target in allowed) if (seen[target] != 1) bad = 1
            exit (bad || NR != count)
        }
    ' || fail "Ghostty patch must modify each approved target exactly once, with no other targets: $patch_path"
done

# Export the verified object, never the working tree, and never include .env* entries.
# Use a file instead of a pipeline so an archive failure cannot be hidden by tar.
git -C "$ghostty_dir" archive --format=tar --output="$stage_dir/source.tar" \
    "$actual_commit" -- . ':(glob,exclude)**/.env*' ':(glob,exclude)**/.env*/**' \
    || fail 'could not export the pinned Ghostty commit'
tar -xf "$stage_dir/source.tar" -C "$source_dir" --exclude='.env*' \
    || fail 'could not unpack the pinned Ghostty source'
for reserved_path in "$source_dir/.git" "$source_dir/.zig-cache" \
    "$source_dir/zig-out" "$source_dir/macos/GhosttyKit.xcframework"; do
    safe_path "$reserved_path" || fail "unsafe exported generated path: $reserved_path"
    [ ! -e "$reserved_path" ] || fail "export already contains a reserved generated path: $reserved_path"
done
for patch_name in $patch_names; do
    patch_snapshot=$stage_dir/patches/$patch_name
    patch_target_paths=$(patch_targets "$patch_name") || fail "could not resolve Ghostty patch targets: $patch_name"
    for patch_target_path in $patch_target_paths; do
        safe_path "$source_dir/$patch_target_path" || fail 'unsafe staged patch target'
        [ -f "$source_dir/$patch_target_path" ] || fail "staged patch target is not a regular file: $patch_target_path"
    done
    # Applying from a subdirectory could resolve paths against the outer repository.
    git -C "$repo_root" apply --directory="$source_relative" --check "$patch_snapshot" \
        || fail "Ghostty patch does not apply to the pinned snapshot: $patch_name"
    git -C "$repo_root" apply --directory="$source_relative" "$patch_snapshot" \
        || fail "could not apply staged Ghostty patch: $patch_name"
    for patch_target_path in $patch_target_paths; do
        safe_path "$source_dir/$patch_target_path" || fail 'unsafe patched target'
        [ -f "$source_dir/$patch_target_path" ] || fail "patched target is not a regular file: $patch_target_path"
    done
done

script_checksum=$(archive_sha256 "$script_dir/build-ghostty.sh") || fail 'could not checksum Ghostty build script'
cache_key_input=$stage_dir/cache-key.txt
cp "$patch_manifest_path" "$cache_key_input" || fail 'could not record Ghostty cache key patches'
printf 'ghostty=%s\nzig=%s\nxcode-build=%s\nscript=%s\n' \
    "$actual_commit" "$zig_version" "$xcode_build_version" "$script_checksum" \
    >>"$cache_key_input" || fail 'could not record Ghostty cache key tools'
printf 'flag=%s\n' "$@" >>"$cache_key_input" || fail 'could not record Ghostty cache key flags'
cache_key=$(archive_sha256 "$cache_key_input") || fail 'could not calculate Ghostty build cache key'
stamp_path=$cache_dir/$cache_key.stamp
safe_path "$stamp_path" || fail 'unsafe Ghostty cache stamp path'
if [ -e "$stamp_path" ] && [ ! -f "$stamp_path" ]; then
    fail "Ghostty cache stamp is not a regular file: $stamp_path"
fi

if [ "$QUICKTTY_FORCE_GHOSTTY_REBUILD" = 0 ] && validate_cached_xcframework; then
    cache_reused=1
    printf 'Reusing cached GhosttyKit XCFramework after checksum, required symbol, and resource validation: %s\n' "$xcframework_dir"
    exit 0
fi

if [ "$QUICKTTY_FORCE_GHOSTTY_REBUILD" = 1 ]; then
    cache_validation_error='forced Ghostty rebuild requested by QUICKTTY_FORCE_GHOSTTY_REBUILD=1'
fi

printf 'Building staged Ghostty (%s); preserving previous outputs and stamp: %s\n' \
    "$cache_validation_error" "$stamp_path" >&2
xcframework_dir=$source_dir/macos/GhosttyKit.xcframework
staged_share_dir=$source_dir/zig-out/share
printf 'Ghostty build log: %s\n' "$stage_dir/build.log"
if (
    cd "$source_dir" || exit 1
    zig build "$@"
) >"$stage_dir/build.log" 2>&1; then
    :
else
    build_status=$?
    printf 'error: Ghostty build failed (%s); see %s\n' "$build_status" "$stage_dir/build.log" >&2
    exit "$build_status"
fi

safe_directory "$source_dir/.zig-cache" || fail 'unsafe staged Zig cache'
safe_directory "$xcframework_dir" || fail 'unsafe staged XCFramework'
validate_share "$staged_share_dir" || fail 'staged Ghostty share resources are missing or unsafe'
[ -f "$xcframework_dir/Info.plist" ] || fail 'staged GhosttyKit Info.plist is missing'
[ -d "$xcframework_dir" ] || fail "Ghostty build completed without producing $xcframework_dir"
locate_fat_archive || fail "Ghostty build must produce exactly one libghostty-fat.a in $xcframework_dir; found $fat_archive_count"

source_archive=
source_archive_count=0
for source_archive_candidate in "$source_dir"/.zig-cache/o/*/libghostty.a; do
    [ -f "$source_archive_candidate" ] || continue
    safe_path "$source_archive_candidate" || fail "unsafe staged native archive: $source_archive_candidate"
    archive_exports_symbol "$source_archive_candidate" _ghostty_init || continue

    source_archive=$source_archive_candidate
    source_archive_count=$((source_archive_count + 1))
done

[ "$source_archive_count" -eq 1 ] || fail "expected exactly one native .zig-cache/o/*/libghostty.a exporting _ghostty_init; found $source_archive_count"
source_archive_relative=${source_archive#"$source_dir"/}
printf 'Selected native Ghostty archive: %s\n' "$source_archive"

repack_dir=$(mktemp -d "$stage_dir/archive-repack.XXXXXX") || fail "could not create Ghostty archive repack directory"
safe_directory "$repack_dir" || fail 'unsafe Ghostty repack directory'
candidate_inputs_path=$repack_dir/candidate-inputs.txt
selected_manifest_path=
manifest_count=0
selected_manifest_archive_count=0
for manifest_candidate in "$source_dir"/.zig-cache/h/*.txt; do
    [ -f "$manifest_candidate" ] || continue
    safe_path "$manifest_candidate" || fail "unsafe staged Zig manifest: $manifest_candidate"
    manifest_contains_archive "$manifest_candidate" "$source_archive_relative" || continue

    validate_manifest_inputs "$manifest_candidate" "$candidate_inputs_path"
    [ "$manifest_archive_count" -ge 2 ] || continue

    selected_manifest_path=$manifest_candidate
    selected_manifest_archive_count=$manifest_archive_count
    manifest_count=$((manifest_count + 1))
done

[ "$manifest_count" -eq 1 ] || fail "expected exactly one Zig cache manifest containing $source_archive_relative and at least two existing archive inputs; found $manifest_count"
printf 'Selected Zig archive manifest: %s (%s archives)\n' "$selected_manifest_path" "$selected_manifest_archive_count"

archive_inputs_path=$repack_dir/archive-inputs.txt
validate_manifest_inputs "$selected_manifest_path" "$archive_inputs_path"
[ "$manifest_archive_count" -eq "$selected_manifest_archive_count" ] \
    || fail "Zig cache manifest archive inputs changed during repack preparation: $selected_manifest_path"

repacked_archive=$repack_dir/libghostty-fat.a
mri_path=$repack_dir/repack.mri
{
    printf 'create %s\n' "$repacked_archive" || fail 'could not write MRI archive destination'
    while IFS= read -r archive_relative || [ -n "$archive_relative" ]; do
        printf 'addlib %s/%s\n' "$source_dir" "$archive_relative" || fail 'could not write MRI archive input'
    done <"$archive_inputs_path" || fail 'could not read MRI archive inputs'
    printf 'save\nend\n' || fail 'could not finish MRI stream'
} >"$mri_path" || fail "could not create zig ar MRI stream"

zig ar -M <"$mri_path" || fail "could not repack Ghostty archive from Zig build manifest"
ranlib "$repacked_archive" || fail "could not index repacked Ghostty archive"
ar -t "$repacked_archive" >/dev/null 2>&1 || fail "repacked Ghostty output is not a valid archive: $repacked_archive"
archive_has_required_symbols "$repacked_archive" \
    || fail "repacked Ghostty archive failed representative bundled symbol validation: $repacked_archive"

safe_path "$repacked_archive" || fail 'unsafe repacked Ghostty archive'
safe_path "$fat_archive" || fail 'unsafe generated Ghostty archive'
printf 'Replacing staged Ghostty archive: %s (from %s)\n' "$fat_archive" "$repacked_archive" >&2
mv -f "$repacked_archive" "$fat_archive" || fail "could not atomically replace generated Ghostty archive"
printf 'Repacked generated Ghostty archive from %s manifest inputs: %s\n' \
    "$selected_manifest_archive_count" "$fat_archive"

archive_has_required_symbols "$fat_archive" || fail "generated Ghostty archive failed representative bundled symbol validation: $fat_archive"
printf 'Validated representative bundled Ghostty symbols: %s\n' "$fat_archive"

final_archive_checksum=$(archive_sha256 "$fat_archive") || fail "could not checksum generated Ghostty archive: $fat_archive"
temporary_stamp=$stage_dir/completed.stamp
safe_path "$temporary_stamp" || fail 'unsafe temporary Ghostty cache stamp path'
[ ! -e "$temporary_stamp" ] || fail 'temporary Ghostty cache stamp already exists'
printf 'cache-key=%s\narchive-sha256=%s\n' "$cache_key" "$final_archive_checksum" \
    >"$temporary_stamp" || fail 'could not write temporary Ghostty cache stamp'

safe_directory "$published_xcframework_dir" || fail 'unsafe GhosttyKit publication path'
safe_directory "$published_share_dir" || fail 'unsafe Ghostty resource publication path'
mkdir -p "$ghostty_dir/macos" "$ghostty_dir/zig-out"
# Rollback relies on rename, not an interruptible cross-filesystem copy-and-delete.
stage_device=$(stat -f %d "$stage_dir") || fail 'could not determine Ghostty stage filesystem'
xcframework_device=$(stat -f %d "$ghostty_dir/macos") || fail 'could not determine GhosttyKit filesystem'
share_device=$(stat -f %d "$ghostty_dir/zig-out") || fail 'could not determine Ghostty share filesystem'
[ "$stage_device" = "$xcframework_device" ] && [ "$stage_device" = "$share_device" ] \
    || fail 'Ghostty stage and publication directories must be on the same filesystem'
for backup_path in "$stage_dir/previous-xcframework" "$stage_dir/previous-share" "$stage_dir/previous.stamp"; do
    safe_path "$backup_path" || fail "unsafe Ghostty backup path: $backup_path"
    [ ! -e "$backup_path" ] || fail "Ghostty backup path already exists: $backup_path"
done
safe_path "$stamp_path" || fail 'unsafe Ghostty cache stamp path'
if [ -e "$stamp_path" ]; then
    [ -f "$stamp_path" ] || fail 'Ghostty cache stamp is not a regular file'
    cp "$stamp_path" "$stage_dir/previous.stamp" || fail 'could not back up Ghostty cache stamp'
    stamp_had_original=1
fi
safe_directory "$xcframework_dir" || fail 'unsafe staged XCFramework publication source'
safe_directory "$published_xcframework_dir" || fail 'unsafe GhosttyKit publication path'

printf 'Publishing verified GhosttyKit: %s -> %s (backup: %s)\n' \
    "$xcframework_dir" "$published_xcframework_dir" "$stage_dir/previous-xcframework" >&2
if [ -d "$published_xcframework_dir" ]; then
    xcframework_had_original=1
    xcframework_replacement_started=1
    mv "$published_xcframework_dir" "$stage_dir/previous-xcframework"
else
    xcframework_replacement_started=1
fi
mv "$xcframework_dir" "$published_xcframework_dir"

safe_directory "$staged_share_dir" || fail 'unsafe staged resource publication source'
safe_directory "$published_share_dir" || fail 'unsafe Ghostty resource publication path'
printf 'Publishing verified Ghostty share: %s -> %s (backup: %s)\n' \
    "$staged_share_dir" "$published_share_dir" "$stage_dir/previous-share" >&2
if [ -d "$published_share_dir" ]; then
    share_had_original=1
    share_replacement_started=1
    mv "$published_share_dir" "$stage_dir/previous-share"
else
    share_replacement_started=1
fi
mv "$staged_share_dir" "$published_share_dir"

# Validate the public paths before the stamp makes this build reusable.
xcframework_dir=$published_xcframework_dir
locate_fat_archive || fail 'published GhosttyKit must contain exactly one libghostty-fat.a'
archive_has_required_symbols "$fat_archive" || fail 'published Ghostty archive failed symbol validation'
published_archive_checksum=$(archive_sha256 "$fat_archive") || fail 'could not checksum published Ghostty archive'
[ "$published_archive_checksum" = "$final_archive_checksum" ] || fail 'published Ghostty archive checksum changed'
validate_share "$published_share_dir" || fail 'published Ghostty resources failed validation'
safe_path "$stamp_path" || fail 'unsafe Ghostty cache stamp path'
safe_path "$temporary_stamp" || fail 'unsafe temporary Ghostty cache stamp path'
if [ -e "$stamp_path" ] && [ ! -f "$stamp_path" ]; then
    fail 'Ghostty cache stamp is no longer a regular file'
fi
printf 'Publishing verified Ghostty cache stamp last: %s\n' "$stamp_path" >&2
stamp_replacement_started=1
mv -f "$temporary_stamp" "$stamp_path" || fail 'could not atomically replace Ghostty cache stamp'
publish_complete=1
printf 'GhosttyKit XCFramework: %s\nGhostty share resources: %s\n' \
    "$xcframework_dir" "$published_share_dir"
