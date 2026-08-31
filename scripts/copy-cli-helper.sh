#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
exec /usr/bin/xcrun --sdk macosx swift "$script_dir/CopyCLIHelper.swift" "$@"
