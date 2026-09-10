#!/bin/sh
set -eu

DEFAULT_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
selected_developer_dir=${DEVELOPER_DIR:-$DEFAULT_DEVELOPER_DIR}

if [ ! -d "$selected_developer_dir" ]; then
    printf 'error: developer directory does not exist: %s\n' "$selected_developer_dir" >&2
    exit 1
fi

if ! canonical_developer_dir=$(CDPATH= cd -P "$selected_developer_dir" && pwd -P); then
    printf 'error: could not resolve developer directory: %s\n' "$selected_developer_dir" >&2
    exit 1
fi
selected_developer_dir=$canonical_developer_dir

xcodebuild_path=$selected_developer_dir/usr/bin/xcodebuild
if [ ! -x "$xcodebuild_path" ]; then
    printf 'error: xcodebuild is not executable in selected developer directory: %s\n' "$xcodebuild_path" >&2
    exit 1
fi

DEVELOPER_DIR=$selected_developer_dir
export DEVELOPER_DIR
for argument in "$@"; do
    case "$argument" in
        test | test-without-building)
            script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
            exec /usr/bin/python3 "$script_dir/xcode-test-watchdog.py" "$xcodebuild_path" "$@"
            ;;
    esac
done
exec "$xcodebuild_path" "$@"
