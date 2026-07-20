#!/bin/sh
set -eu

DEFAULT_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
REQUIRED_GHOSTTY_COMMIT=332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28
REQUIRED_ZIG_VERSION=0.15.2
GHOSTTERM_FORCE_GHOSTTY_REBUILD=${GHOSTTERM_FORCE_GHOSTTY_REBUILD:-0}

case "$GHOSTTERM_FORCE_GHOSTTY_REBUILD" in
    0 | 1) ;;
    *)
        printf '%s\n' 'error: GHOSTTERM_FORCE_GHOSTTY_REBUILD must be unset, 0, or 1' >&2
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

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
repo_root=$(CDPATH= cd "$script_dir/.." && pwd)
ghostty_dir=$repo_root/Vendor/ghostty
xcframework_dir=$ghostty_dir/macos/GhosttyKit.xcframework
cache_dir=$repo_root/.build/ghostty

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

        archive_absolute=$ghostty_dir/$archive_relative
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
    -Doptimize=ReleaseFast

script_checksum=$(shasum -a 256 "$script_dir/build-ghostty.sh") || fail "could not checksum Ghostty build script"
script_checksum=${script_checksum%% *}
cache_key=$(
    {
        printf 'ghostty=%s\nzig=%s\nxcode-build=%s\nscript=%s\n' \
            "$actual_commit" "$zig_version" "$xcode_build_version" "$script_checksum"
        printf 'flag=%s\n' "$@"
    } | shasum -a 256
) || fail "could not calculate Ghostty build cache key"
cache_key=${cache_key%% *}
stamp_path=$cache_dir/$cache_key.stamp

if [ "$GHOSTTERM_FORCE_GHOSTTY_REBUILD" = 0 ] && validate_cached_xcframework; then
    printf 'Reusing cached GhosttyKit XCFramework after checksum and required symbol validation: %s\n' "$xcframework_dir"
    exit 0
fi

if [ "$GHOSTTERM_FORCE_GHOSTTY_REBUILD" = 1 ]; then
    cache_validation_error='forced Ghostty rebuild requested by GHOSTTERM_FORCE_GHOSTTY_REBUILD=1'
fi

if [ -f "$stamp_path" ]; then
    printf 'Removing current generated Ghostty cache stamp before rebuild (%s): %s\n' \
        "$cache_validation_error" "$stamp_path" >&2
else
    printf 'Ghostty cache is not reusable (%s); ensuring the current generated stamp is absent before rebuild: %s\n' \
        "$cache_validation_error" "$stamp_path" >&2
fi
rm -f "$stamp_path"

(
    cd "$ghostty_dir"
    zig build "$@"
)

[ -d "$xcframework_dir" ] || fail "Ghostty build completed without producing $xcframework_dir"
locate_fat_archive || fail "Ghostty build must produce exactly one libghostty-fat.a in $xcframework_dir; found $fat_archive_count"

source_archive=
source_archive_count=0
for source_archive_candidate in "$ghostty_dir"/.zig-cache/o/*/libghostty.a; do
    [ -f "$source_archive_candidate" ] || continue
    archive_exports_symbol "$source_archive_candidate" _ghostty_init || continue

    source_archive=$source_archive_candidate
    source_archive_count=$((source_archive_count + 1))
done

[ "$source_archive_count" -eq 1 ] || fail "expected exactly one native .zig-cache/o/*/libghostty.a exporting _ghostty_init; found $source_archive_count"
source_archive_relative=${source_archive#"$ghostty_dir"/}
printf 'Selected native Ghostty archive: %s\n' "$source_archive"

mkdir -p "$cache_dir"
repack_dir=
temporary_stamp=
cleanup() {
    cleanup_result=0

    if [ -n "$repack_dir" ]; then
        rm -rf "$repack_dir" || cleanup_result=1
    fi
    if [ -n "$temporary_stamp" ]; then
        rm -f "$temporary_stamp" || cleanup_result=1
    fi

    return "$cleanup_result"
}

cleanup_exit() {
    cleanup_status=$?
    trap - EXIT HUP INT TERM

    cleanup || printf '%s\n' 'error: could not remove temporary Ghostty build files' >&2
    exit "$cleanup_status"
}

handle_signal() {
    signal_status=$1
    trap - EXIT HUP INT TERM

    cleanup || printf '%s\n' 'error: could not remove temporary Ghostty build files' >&2
    exit "$signal_status"
}

trap cleanup_exit EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

repack_dir=$(mktemp -d "$cache_dir/archive-repack.XXXXXX") || fail "could not create Ghostty archive repack directory"
candidate_inputs_path=$repack_dir/candidate-inputs.txt
selected_manifest_path=
manifest_count=0
selected_manifest_archive_count=0
for manifest_candidate in "$ghostty_dir"/.zig-cache/h/*.txt; do
    [ -f "$manifest_candidate" ] || continue
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
    printf 'create %s\n' "$repacked_archive"
    while IFS= read -r archive_relative || [ -n "$archive_relative" ]; do
        printf 'addlib %s/%s\n' "$ghostty_dir" "$archive_relative"
    done <"$archive_inputs_path"
    printf 'save\nend\n'
} >"$mri_path" || fail "could not create zig ar MRI stream"

zig ar -M <"$mri_path" || fail "could not repack Ghostty archive from Zig build manifest"
ranlib "$repacked_archive" || fail "could not index repacked Ghostty archive"
ar -t "$repacked_archive" >/dev/null 2>&1 || fail "repacked Ghostty output is not a valid archive: $repacked_archive"
archive_has_required_symbols "$repacked_archive" \
    || fail "repacked Ghostty archive failed representative bundled symbol validation: $repacked_archive"

mv -f "$repacked_archive" "$fat_archive" || fail "could not atomically replace generated Ghostty archive"
printf 'Repacked generated Ghostty archive from %s manifest inputs: %s\n' \
    "$selected_manifest_archive_count" "$fat_archive"

archive_has_required_symbols "$fat_archive" || fail "generated Ghostty archive failed representative bundled symbol validation: $fat_archive"
printf 'Validated representative bundled Ghostty symbols: %s\n' "$fat_archive"

final_archive_checksum=$(archive_sha256 "$fat_archive") || fail "could not checksum generated Ghostty archive: $fat_archive"
temporary_stamp=$stamp_path.tmp.$$
{
    printf 'cache-key=%s\n' "$cache_key"
    printf 'archive-sha256=%s\n' "$final_archive_checksum"
} >"$temporary_stamp" || fail "could not write temporary Ghostty cache stamp"
mv -f "$temporary_stamp" "$stamp_path" || fail "could not atomically replace Ghostty cache stamp"
temporary_stamp=
cleanup || fail 'could not remove temporary Ghostty build files'
trap - EXIT HUP INT TERM
printf 'GhosttyKit XCFramework: %s\n' "$xcframework_dir"
