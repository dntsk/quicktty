#!/bin/sh
set -eu

DEFAULT_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
MINIMUM_XCODEGEN_VERSION=2.45.4
REQUIRED_ZIG_VERSION=0.15.2

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "$DEFAULT_DEVELOPER_DIR" ]; then
    DEVELOPER_DIR=$DEFAULT_DEVELOPER_DIR
    export DEVELOPER_DIR
fi

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

is_numeric_version() {
    version=$1

    case "$version" in
        *.*.*) ;;
        *) return 1 ;;
    esac
    case "$version" in
        *.*.*.*) return 1 ;;
    esac

    major=${version%%.*}
    remainder=${version#*.}
    minor=${remainder%%.*}
    patch=${remainder#*.}
    for version_component in "$major" "$minor" "$patch"; do
        case "$version_component" in
            '' | *[!0-9]*) return 1 ;;
        esac
    done
}

version_at_least() {
    is_numeric_version "$1" || return 1
    is_numeric_version "$2" || return 1

    actual=$1
    minimum=$2
    component=1

    while [ "$component" -le 3 ]; do
        case "$actual" in
            *.*)
                actual_component=${actual%%.*}
                actual=${actual#*.}
                ;;
            *)
                actual_component=$actual
                actual=0
                ;;
        esac
        case "$minimum" in
            *.*)
                minimum_component=${minimum%%.*}
                minimum=${minimum#*.}
                ;;
            *)
                minimum_component=$minimum
                minimum=0
                ;;
        esac

        case "$actual_component:$minimum_component" in
            *[!0-9:]* | :* | *:)
                return 1
                ;;
        esac

        if [ "$actual_component" -gt "$minimum_component" ]; then
            return 0
        fi
        if [ "$actual_component" -lt "$minimum_component" ]; then
            return 1
        fi

        component=$((component + 1))
    done

    return 0
}

require_command xcrun
xcodebuild_path=$(xcrun --find xcodebuild 2>/dev/null) || fail "full Xcode is required; xcodebuild was not found"
case "$xcodebuild_path" in
    */Contents/Developer/usr/bin/xcodebuild) ;;
    *) fail "full Xcode is required; selected developer directory appears to be Command Line Tools only" ;;
esac
xcode_version=$("$xcodebuild_path" -version 2>&1) || fail "xcodebuild is unavailable from the selected developer directory"
metal_path=$(xcrun -sdk macosx --find metal 2>/dev/null) || fail "Xcode Metal Toolchain is required; install it with 'xcodebuild -downloadComponent MetalToolchain'"

require_command xcodegen
xcodegen_output=$(xcodegen --version 2>&1) || fail "could not determine XcodeGen version"
xcodegen_version=$(
    printf '%s\n' "$xcodegen_output" | while IFS=' ' read -r label value extra; do
        if [ "$label" = "Version:" ] && [ -n "$value" ] && [ -z "$extra" ]; then
            printf '%s\n' "$value"
            break
        fi
    done
)
[ -n "$xcodegen_version" ] || fail "could not parse XcodeGen version from: $xcodegen_output"
version_at_least "$xcodegen_version" "$MINIMUM_XCODEGEN_VERSION" || fail "XcodeGen $MINIMUM_XCODEGEN_VERSION or newer is required; found $xcodegen_version"

require_command swift
swift_format_version=$(swift format --version 2>&1) || fail "Apple Swift Format is required and must be available as 'swift format'"

require_command zig
zig_version=$(zig version 2>&1) || fail "could not determine Zig version"
[ "$zig_version" = "$REQUIRED_ZIG_VERSION" ] || fail "Zig $REQUIRED_ZIG_VERSION is required for the pinned Ghostty revision; found $zig_version"

printf 'Xcode: %s\n%s\n' "$xcodebuild_path" "$xcode_version"
printf 'Metal: %s\n' "$metal_path"
printf 'XcodeGen: %s\n' "$xcodegen_version"
printf 'Swift Format: %s\n' "$swift_format_version"
printf 'Zig: %s\n' "$zig_version"
