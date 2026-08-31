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

MARKETING_VERSION=0.1.3
BUILD_NUMBER=10
BUNDLE_IDENTIFIER=com.dntsk.QuickTTY
MINIMUM_SYSTEM_VERSION=15.0
PRODUCT_NAME=QuickTTY
CLI_HELPER_NAME=quicktty
CLI_HELPER_IDENTIFIER=com.dntsk.QuickTTY.cli
VOLUME_NAME="QuickTTY $RELEASE_LABEL_DEFAULT"
DEFAULT_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

require_executable_path() {
    [ -x "$1" ] || release_fail "required tool is not executable: $1"
}

resolve_selected_xcode_tool() {
    xcode_tool_name=$1
    xcode_tool_path=$("$xcrun_path" --find "$xcode_tool_name" 2>/dev/null) \
        || release_fail "$xcode_tool_name was not found in the selected DEVELOPER_DIR"
    [ -x "$xcode_tool_path" ] \
        || release_fail "$xcode_tool_name is not executable in the selected DEVELOPER_DIR: $xcode_tool_path"
    case "$xcode_tool_path" in
        "$DEVELOPER_DIR"/*) ;;
        *) release_fail "$xcode_tool_name resolved outside the selected DEVELOPER_DIR: $xcode_tool_path" ;;
    esac
    printf '%s\n' "$xcode_tool_path"
}

require_regular_file() {
    [ -f "$1" ] || release_fail "required file is missing: $1"
    [ ! -L "$1" ] || release_fail "required file must not be a symlink: $1"
}

require_directory() {
    [ -d "$1" ] || release_fail "required directory is missing: $1"
    [ ! -L "$1" ] || release_fail "required directory must not be a symlink: $1"
}

verify_agent_session_integrations() {
    resources_dir=$1
    integrations_dir=$resources_dir/AgentSessionIntegrations
    source_integrations_dir=$repo_root/QuickTTY/Resources/AgentSessionIntegrations

    require_directory "$integrations_dir"
    for adapter in \
        amp antigravity claude codex copilot cursor droid gemini hermes kimi omp opencode pi qoder
    do
        require_directory "$integrations_dir/$adapter"
        require_regular_file "$integrations_dir/$adapter/integration.json"
        /usr/bin/cmp -s \
            "$source_integrations_dir/$adapter/integration.json" \
            "$integrations_dir/$adapter/integration.json" \
            || release_fail "bundled integration manifest differs from source: $adapter"
    done
    for wrapper_adapter in amp antigravity opencode; do
        require_directory "$integrations_dir/$wrapper_adapter/wrapper"
    done
    for required_resource in \
        amp/plugin.json \
        amp/wrapper/amp \
        antigravity/hook.json \
        antigravity/wrapper/agy \
        opencode/plugin.js \
        opencode/wrapper/opencode \
        pi/index.ts
    do
        require_regular_file "$integrations_dir/$required_resource"
        /usr/bin/cmp -s \
            "$source_integrations_dir/$required_resource" \
            "$integrations_dir/$required_resource" \
            || release_fail "bundled integration resource differs from source: $required_resource"
    done

    for blocked_adapter in grok campfire kiro rovo-dev codebuddy ollama; do
        [ ! -e "$integrations_dir/$blocked_adapter" ] && [ ! -L "$integrations_dir/$blocked_adapter" ] \
            || release_fail "blocked adapter resource must be absent: $integrations_dir/$blocked_adapter"
    done

    integration_entry_count=$("$RELEASE_FIND_PATH" "$integrations_dir" -mindepth 1 -print \
        | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    [ "$integration_entry_count" = 38 ] \
        || release_fail "AgentSessionIntegrations resource set is not exact: $integrations_dir"
    integration_directory_count=$("$RELEASE_FIND_PATH" "$integrations_dir" -mindepth 1 -type d -print \
        | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    [ "$integration_directory_count" = 17 ] \
        || release_fail "AgentSessionIntegrations directory set is not exact: $integrations_dir"
    integration_file_count=$("$RELEASE_FIND_PATH" "$integrations_dir" -mindepth 1 -type f -print \
        | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    [ "$integration_file_count" = 21 ] \
        || release_fail "AgentSessionIntegrations file set is not exact: $integrations_dir"
    if "$RELEASE_FIND_PATH" "$integrations_dir" -mindepth 1 -type l -print | /usr/bin/grep . >/dev/null; then
        release_fail "AgentSessionIntegrations must not contain symlinks: $integrations_dir"
    fi

    for wrapper_resource in \
        amp/wrapper/amp antigravity/wrapper/agy opencode/wrapper/opencode
    do
        [ "$("$stat_path" -f '%Lp' "$integrations_dir/$wrapper_resource")" = 755 ] \
            || release_fail "wrapper resource mode must be 0755: $integrations_dir/$wrapper_resource"
    done
    for configuration_resource in \
        amp/plugin.json antigravity/hook.json opencode/plugin.js pi/index.ts
    do
        [ "$("$stat_path" -f '%Lp' "$integrations_dir/$configuration_resource")" = 644 ] \
            || release_fail "integration resource mode must be 0644: $integrations_dir/$configuration_resource"
    done
}

plist_value() {
    "$plist_buddy" -c "Print :$2" "$1" 2>/dev/null
}

verify_signature_metadata() {
    release_verify_signature_metadata \
        "$1" "$2" "$3" "$codesign_path" "$CODE_SIGN_IDENTITY" "$DEVELOPMENT_TEAM"
}

verify_cli_helper_signature() {
    signed_app=$1
    cli_helper=$signed_app/Contents/Helpers/$CLI_HELPER_NAME

    release_verify_cli_helper_artifact "$signed_app" "$file_path" "$lipo_path" "$stat_path"
    "$codesign_path" --verify --strict --verbose=4 "$cli_helper" \
        || release_fail "CLI helper did not pass strict code-signature verification: $cli_helper"
    verify_signature_metadata "$cli_helper" "$CLI_HELPER_IDENTIFIER" yes

    cli_helper_entitlements=$("$codesign_path" -d --entitlements :- "$cli_helper" 2>/dev/null) \
        || release_fail "could not inspect CLI helper entitlements: $cli_helper"
    [ -z "$cli_helper_entitlements" ] \
        || release_fail "CLI helper must not contain entitlements: $cli_helper"
}

verify_signed_app_bundle() {
    signed_app=$1

    release_verify_app_code_layout "$signed_app" "$PRODUCT_NAME" "$file_path"
    verify_cli_helper_signature "$signed_app"
    release_verify_nested_code_recursively \
        "$signed_app" "$codesign_path" "$file_path" "$CODE_SIGN_IDENTITY" "$DEVELOPMENT_TEAM"
    "$codesign_path" --verify --strict --deep --verbose=4 "$signed_app" \
        || release_fail "app did not pass strict deep code-signature verification: $signed_app"
}

verify_bundle() {
    archive_app=$1
    info_plist=$archive_app/Contents/Info.plist
    resources_dir=$archive_app/Contents/Resources

    require_directory "$archive_path"
    require_directory "$archive_path/Products/Applications"
    require_directory "$archive_app"
    require_regular_file "$info_plist"
    require_regular_file "$archive_app/Contents/MacOS/$PRODUCT_NAME"
    require_directory "$resources_dir"
    release_verify_app_code_layout "$archive_app" "$PRODUCT_NAME" "$file_path"

    actual_bundle_identifier=$(plist_value "$info_plist" CFBundleIdentifier) \
        || release_fail 'CFBundleIdentifier is missing from archived app'
    [ "$actual_bundle_identifier" = "$BUNDLE_IDENTIFIER" ] \
        || release_fail "unexpected CFBundleIdentifier: $actual_bundle_identifier"

    actual_display_name=$(plist_value "$info_plist" CFBundleDisplayName) \
        || release_fail 'CFBundleDisplayName is missing from archived app'
    [ "$actual_display_name" = QuickTTY ] \
        || release_fail "unexpected CFBundleDisplayName: $actual_display_name"

    actual_bundle_name=$(plist_value "$info_plist" CFBundleName) \
        || release_fail 'CFBundleName is missing from archived app'
    [ "$actual_bundle_name" = QuickTTY ] \
        || release_fail "unexpected CFBundleName: $actual_bundle_name"

    actual_bundle_package_type=$(plist_value "$info_plist" CFBundlePackageType) \
        || release_fail 'CFBundlePackageType is missing from archived app'
    [ "$actual_bundle_package_type" = APPL ] \
        || release_fail "unexpected CFBundlePackageType: $actual_bundle_package_type"

    actual_marketing_version=$(plist_value "$info_plist" CFBundleShortVersionString) \
        || release_fail 'CFBundleShortVersionString is missing from archived app'
    [ "$actual_marketing_version" = "$MARKETING_VERSION" ] \
        || release_fail "unexpected CFBundleShortVersionString: $actual_marketing_version"

    actual_build_number=$(plist_value "$info_plist" CFBundleVersion) \
        || release_fail 'CFBundleVersion is missing from archived app'
    [ "$actual_build_number" = "$BUILD_NUMBER" ] \
        || release_fail "unexpected CFBundleVersion: $actual_build_number"

    actual_minimum_system_version=$(plist_value "$info_plist" LSMinimumSystemVersion) \
        || release_fail 'LSMinimumSystemVersion is missing from archived app'
    [ "$actual_minimum_system_version" = "$MINIMUM_SYSTEM_VERSION" ] \
        || release_fail "unexpected LSMinimumSystemVersion: $actual_minimum_system_version"

    actual_executable_name=$(plist_value "$info_plist" CFBundleExecutable) \
        || release_fail 'CFBundleExecutable is missing from archived app'
    [ "$actual_executable_name" = "$PRODUCT_NAME" ] \
        || release_fail "unexpected CFBundleExecutable: $actual_executable_name"

    actual_icon_file=$(plist_value "$info_plist" CFBundleIconFile) \
        || release_fail 'CFBundleIconFile is missing from archived app'
    [ "$actual_icon_file" = AppIcon ] \
        || release_fail "unexpected CFBundleIconFile: $actual_icon_file"

    actual_icon_name=$(plist_value "$info_plist" CFBundleIconName) \
        || release_fail 'CFBundleIconName is missing from archived app'
    [ "$actual_icon_name" = AppIcon ] \
        || release_fail "unexpected CFBundleIconName: $actual_icon_name"
    require_regular_file "$resources_dir/AppIcon.icns"
    require_regular_file "$resources_dir/Assets.car"

    require_regular_file "$resources_dir/terminfo/78/xterm-ghostty"
    require_directory "$resources_dir/ghostty/shell-integration"
    require_directory "$resources_dir/ghostty/themes"
    require_regular_file "$resources_dir/ThirdPartyNotices.txt"
    verify_agent_session_integrations "$resources_dir"

    architectures=$("$lipo_path" -archs "$archive_app/Contents/MacOS/$PRODUCT_NAME") \
        || release_fail 'could not determine executable architectures'
    [ "$architectures" = arm64 ] \
        || release_fail "executable must contain arm64 only; found: $architectures"

    if [ -e "$archive_app/Contents/Frameworks/GhosttyKit.framework" ] \
        || [ -L "$archive_app/Contents/Frameworks/GhosttyKit.framework" ]; then
        release_fail 'GhosttyKit.framework must not be embedded; Ghostty is linked statically'
    fi

    sparkle_linked=yes
    if [ -e "$archive_app/Contents/Frameworks/Sparkle.framework" ] \
        || [ -L "$archive_app/Contents/Frameworks/Sparkle.framework" ]; then
        sparkle_linked=no
    fi
    [ "$sparkle_linked" = no ] \
        || release_fail 'Sparkle.framework must be embedded in Frameworks'
    release_verify_sparkle_signing_layout "$archive_app"

    linked_libraries=$("$otool_path" -L "$archive_app/Contents/MacOS/$PRODUCT_NAME") \
        || release_fail 'could not inspect executable linked libraries'
    ghosttykit_linked=no
    while IFS= read -r linked_library || [ -n "$linked_library" ]; do
        case "$linked_library" in
            *GhosttyKit.framework*) ghosttykit_linked=yes ;;
        esac
    done <<EOF
$linked_libraries
EOF
    [ "$ghosttykit_linked" = no ] \
        || release_fail 'executable references GhosttyKit.framework instead of the static library'

    "$codesign_path" --verify --strict --verbose=4 "$archive_app" \
        || release_fail "archived app did not pass strict code-signature verification: $archive_app"
    verify_signature_metadata "$archive_app" "$BUNDLE_IDENTIFIER" yes

    app_entitlements=$("$codesign_path" -d --entitlements :- "$archive_app" 2>/dev/null) \
        || release_fail 'could not read archived app entitlements'
    case "$app_entitlements" in
        *com.apple.security.get-task-allow*)
            release_fail 'archived app contains forbidden get-task-allow entitlement'
            ;;
    esac

    verify_cli_helper_signature "$archive_app"
}

stage_created=no
archive_pending=no
dmg_pending=no

cleanup_release_outputs() {
    cleanup_status=$1
    trap - 0 HUP INT TERM

    if ! release_cleanup_nested_code_list; then
        printf '%s\n' 'error: could not remove nested code list' >&2
    fi
    if [ "$stage_created" = yes ]; then
        if ! release_remove_generated_directory "$release_dir" "$stage_dir"; then
            printf 'error: could not remove generated staging directory: %s\n' "$stage_dir" >&2
        fi
    fi
    if [ "$dmg_pending" = yes ]; then
        if ! release_remove_generated_file "$release_dir" "$dmg_path"; then
            printf 'error: could not remove incomplete release DMG: %s\n' "$dmg_path" >&2
        fi
    fi
    if [ "$archive_pending" = yes ]; then
        if ! release_remove_generated_directory "$release_dir" "$archive_path"; then
            printf 'error: could not remove incomplete release archive: %s\n' "$archive_path" >&2
        fi
    fi

    exit "$cleanup_status"
}

cleanup_release_exit() {
    cleanup_release_outputs "$?"
}

handle_release_signal() {
    cleanup_release_outputs "$1"
}

release_require_no_arguments "$@"
release_reject_secret_environment

RELEASE_LABEL=${RELEASE_LABEL:-$RELEASE_LABEL_DEFAULT}
release_validate_label "$RELEASE_LABEL"
release_validate_team "${DEVELOPMENT_TEAM:-}"
release_validate_identity "${CODE_SIGN_IDENTITY:-}"

[ -e "$repo_root/.git" ] || release_fail "not a Git repository: $repo_root"
[ -f "$repo_root/project.yml" ] || release_fail "project.yml is missing: $repo_root/project.yml"
[ -x "$script_dir/build-ghostty.sh" ] || release_fail "Ghostty build script is not executable: $script_dir/build-ghostty.sh"
[ -x "$script_dir/copy-cli-helper.sh" ] || release_fail "CLI helper copy script is not executable: $script_dir/copy-cli-helper.sh"

DEVELOPER_DIR=${DEVELOPER_DIR:-$DEFAULT_DEVELOPER_DIR}
[ -d "$DEVELOPER_DIR" ] || release_fail "DEVELOPER_DIR is not an existing directory: $DEVELOPER_DIR"
developer_dir_canonical=$(CDPATH= cd -P "$DEVELOPER_DIR" && pwd -P) \
    || release_fail "could not resolve DEVELOPER_DIR: $DEVELOPER_DIR"
DEVELOPER_DIR=$developer_dir_canonical
export DEVELOPER_DIR

codesign_path=/usr/bin/codesign
hdiutil_path=/usr/bin/hdiutil
ditto_path=/usr/bin/ditto
xcrun_path=/usr/bin/xcrun
readlink_path=/usr/bin/readlink
file_path=/usr/bin/file
stat_path=/usr/bin/stat
git_path=/usr/bin/git
plist_buddy=/usr/libexec/PlistBuddy
mkdir_path=/bin/mkdir
ln_path=/bin/ln

for required_tool_path in \
    "$codesign_path" \
    "$hdiutil_path" \
    "$ditto_path" \
    "$xcrun_path" \
    "$readlink_path" \
    "$file_path" \
    "$stat_path" \
    "$git_path" \
    "$plist_buddy" \
    "$mkdir_path" \
    "$ln_path" \
    "$RELEASE_FIND_PATH" \
    "$RELEASE_MKTEMP_PATH" \
    "$RELEASE_CHMOD_PATH" \
    "$RELEASE_MKDIR_PATH" \
    "$RELEASE_RM_PATH"
do
    require_executable_path "$required_tool_path"
done

xcodebuild_path=$(resolve_selected_xcode_tool xcodebuild)
lipo_path=$(resolve_selected_xcode_tool lipo)
otool_path=$(resolve_selected_xcode_tool otool)
homebrew_bin=/opt/homebrew/bin
xcodegen_path=$homebrew_bin/xcodegen
zig_path=$homebrew_bin/zig
require_executable_path "$xcodegen_path"
require_executable_path "$zig_path"
[ "$(command -v xcodegen)" = "$xcodegen_path" ] \
    || release_fail "xcodegen did not resolve from the trusted Homebrew location: $xcodegen_path"
[ "$(command -v zig)" = "$zig_path" ] \
    || release_fail "zig did not resolve from the trusted Homebrew location: $zig_path"

release_dir=$(release_prepare_output_directory "$repo_root")
archive_path=$release_dir/$RELEASE_ARCHIVE_NAME
dmg_path=$release_dir/$RELEASE_DMG_NAME
notary_result_path=$release_dir/$RELEASE_NOTARY_RESULT_NAME
stage_dir=$release_dir/$RELEASE_STAGE_NAME
appcast_dir=$release_dir/$RELEASE_APPCAST_DIRECTORY_NAME

printf '%s\n' 'cleanup: only prior QuickTTY archive, DMG, notarization result, appcast, and staging directory under canonical .build/Release may be removed; unrelated files are preserved.'
release_remove_generated_directory "$release_dir" "$archive_path"
release_remove_generated_file "$release_dir" "$dmg_path"
release_remove_generated_file "$release_dir" "$notary_result_path"
release_remove_generated_directory "$release_dir" "$appcast_dir"
release_remove_generated_directory "$release_dir" "$stage_dir"

trap cleanup_release_exit 0
trap 'handle_release_signal 129' HUP
trap 'handle_release_signal 130' INT
trap 'handle_release_signal 143' TERM

source_revision=$("$git_path" -C "$repo_root" rev-parse HEAD 2>/dev/null) \
    || release_fail 'could not determine base Git revision'
source_tree_state=$(release_source_tree_state "$repo_root" "$git_path") \
    || release_fail 'could not determine source tree state'
printf 'Base Git revision: %s\n' "$source_revision"
printf 'Source tree state: %s\n' "$source_tree_state"
if [ "$source_tree_state" = dirty ]; then
    printf '%s\n' 'warning: source tree is dirty; Base Git revision does not uniquely identify this artifact.' >&2
fi

cd "$repo_root"
release_force_clean_ghostty_generated_resources "$repo_root"
QUICKTTY_FORCE_GHOSTTY_REBUILD=1 "$script_dir/build-ghostty.sh"
release_verify_ghostty_generated_resources "$repo_root"
prepared_source_tree_state=$(release_source_tree_state "$repo_root" "$git_path") \
    || release_fail 'could not determine source tree state after Ghostty resource rebuild'
[ "$prepared_source_tree_state" = "$source_tree_state" ] \
    || release_fail 'source tree state changed during Ghostty resource rebuild'
"$xcodegen_path" generate --spec "$repo_root/project.yml"
archive_pending=yes
"$xcodebuild_path" archive \
    -project "$repo_root/QuickTTY.xcodeproj" \
    -scheme QuickTTY \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$archive_path" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
    OTHER_CODE_SIGN_FLAGS='--timestamp --options runtime'

archive_app=$archive_path/Products/Applications/$PRODUCT_NAME.app
verify_bundle "$archive_app"

cli_build_dir=$archive_path/QuickTTYCLIProducts
[ ! -e "$cli_build_dir" ] && [ ! -L "$cli_build_dir" ] \
    || release_fail "CLI helper build directory must be absent: $cli_build_dir"
"$xcodebuild_path" build \
    -project "$repo_root/QuickTTY.xcodeproj" \
    -target QuickTTYCLI \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    "CONFIGURATION_BUILD_DIR=$cli_build_dir"
cli_build_product=$cli_build_dir/$CLI_HELPER_NAME
require_regular_file "$cli_build_product"
[ -x "$cli_build_product" ] || release_fail "built CLI helper is not executable: $cli_build_product"

"$mkdir_path" "$stage_dir" || release_fail "could not create staging directory: $stage_dir"
stage_created=yes
staged_app=$stage_dir/$PRODUCT_NAME.app
"$ditto_path" "$archive_app" "$staged_app"
"$script_dir/copy-cli-helper.sh" \
    "$cli_build_product" "$staged_app/Contents/Helpers/$CLI_HELPER_NAME"
"$RELEASE_RM_PATH" -rf "$cli_build_dir" \
    || release_fail "could not remove CLI helper build directory: $cli_build_dir"
release_verify_sparkle_signing_layout "$staged_app"

"$codesign_path" --force --sign "$CODE_SIGN_IDENTITY" --timestamp --options runtime \
    --identifier "$CLI_HELPER_IDENTIFIER" \
    "$staged_app/Contents/Helpers/$CLI_HELPER_NAME" \
    || release_fail 'could not sign QuickTTY CLI helper'
verify_cli_helper_signature "$staged_app"

# Re-sign Sparkle binaries with our Developer ID certificate for notarization
"$codesign_path" --force --sign "$CODE_SIGN_IDENTITY" --timestamp --options runtime \
    "$staged_app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
    || release_fail 'could not sign Sparkle Autoupdate'
"$codesign_path" --force --sign "$CODE_SIGN_IDENTITY" --timestamp --options runtime \
    "$staged_app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
    || release_fail 'could not sign Sparkle Installer.xpc'
"$codesign_path" --force --sign "$CODE_SIGN_IDENTITY" --timestamp --options runtime \
    "$staged_app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
    || release_fail 'could not sign Sparkle Downloader.xpc'
"$codesign_path" --force --sign "$CODE_SIGN_IDENTITY" --timestamp --options runtime \
    "$staged_app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
    || release_fail 'could not sign Sparkle Updater.app'
"$codesign_path" --force --sign "$CODE_SIGN_IDENTITY" --timestamp --options runtime \
    "$staged_app/Contents/Frameworks/Sparkle.framework" \
    || release_fail 'could not re-sign Sparkle.framework'
"$codesign_path" --force --sign "$CODE_SIGN_IDENTITY" --timestamp --options runtime \
    "$staged_app" \
    || release_fail 'could not re-sign staged app after Sparkle re-sign'

"$ln_path" -s /Applications "$stage_dir/Applications" \
    || release_fail 'could not create Applications symlink in staging directory'
[ -L "$stage_dir/Applications" ] || release_fail 'Applications staging entry is not a symlink'
[ "$("$readlink_path" "$stage_dir/Applications")" = /Applications ] \
    || release_fail 'Applications staging symlink does not target /Applications'
verify_signed_app_bundle "$staged_app"

release_assert_generated_path_absent "$release_dir" "$dmg_path"
dmg_pending=yes
"$hdiutil_path" create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$stage_dir" \
    -format UDZO \
    "$dmg_path"
release_remove_generated_directory "$release_dir" "$stage_dir"
stage_created=no

"$codesign_path" --force --sign "$CODE_SIGN_IDENTITY" --timestamp "$dmg_path" \
    || release_fail 'could not sign DMG with a secure timestamp'
"$codesign_path" --verify --strict --verbose=4 "$dmg_path" \
    || release_fail 'DMG did not pass strict code-signature verification'
verify_signature_metadata "$dmg_path" '' no

[ -f "$dmg_path" ] || release_fail "release DMG was not created: $dmg_path"
archive_pending=no
dmg_pending=no

trap - 0 HUP INT TERM
printf '%s\n' ".build/Release/$RELEASE_DMG_NAME"
