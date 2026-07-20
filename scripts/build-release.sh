#!/bin/sh
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

MARKETING_VERSION=0.1.0
BUILD_NUMBER=1
BUNDLE_IDENTIFIER=com.dntsk.GhostTerm
MINIMUM_SYSTEM_VERSION=15.0
PRODUCT_NAME=GhostTerm
VOLUME_NAME="GhostTerm $RELEASE_LABEL_DEFAULT"
DEFAULT_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

require_command() {
    command -v "$1" >/dev/null 2>&1 || release_fail "required command not found: $1"
}

require_regular_file() {
    [ -f "$1" ] || release_fail "required file is missing: $1"
    [ ! -L "$1" ] || release_fail "required file must not be a symlink: $1"
}

require_directory() {
    [ -d "$1" ] || release_fail "required directory is missing: $1"
    [ ! -L "$1" ] || release_fail "required directory must not be a symlink: $1"
}

plist_value() {
    "$plist_buddy" -c "Print :$2" "$1" 2>/dev/null
}

signature_has_exact_line() {
    signature_data=$1
    expected_line=$2

    while IFS= read -r signature_line || [ -n "$signature_line" ]; do
        [ "$signature_line" = "$expected_line" ] && return 0
    done <<EOF
$signature_data
EOF

    return 1
}

signature_has_prefix() {
    signature_data=$1
    expected_prefix=$2

    while IFS= read -r signature_line || [ -n "$signature_line" ]; do
        case "$signature_line" in
            "$expected_prefix"*) return 0 ;;
        esac
    done <<EOF
$signature_data
EOF

    return 1
}

verify_signature_metadata() {
    signed_path=$1
    expected_identifier=$2
    require_runtime=$3

    signature_data=$("$codesign_path" -d -vvv "$signed_path" 2>&1) \
        || release_fail "could not display code-signature metadata: $signed_path"

    signature_has_exact_line "$signature_data" "Authority=$CODE_SIGN_IDENTITY" \
        || release_fail "signature authority does not match CODE_SIGN_IDENTITY: $signed_path"
    signature_has_exact_line "$signature_data" "TeamIdentifier=$DEVELOPMENT_TEAM" \
        || release_fail "signature team does not match DEVELOPMENT_TEAM: $signed_path"
    signature_has_prefix "$signature_data" 'Timestamp=' \
        || release_fail "signature has no secure timestamp: $signed_path"

    if [ -n "$expected_identifier" ]; then
        signature_has_exact_line "$signature_data" "Identifier=$expected_identifier" \
            || release_fail "signature identifier does not match bundle identifier: $signed_path"
    fi

    if [ "$require_runtime" = yes ]; then
        release_signature_has_hardened_runtime "$signature_data" \
            || release_fail "hardened runtime flag is missing: $signed_path"
    fi
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

    actual_bundle_identifier=$(plist_value "$info_plist" CFBundleIdentifier) \
        || release_fail 'CFBundleIdentifier is missing from archived app'
    [ "$actual_bundle_identifier" = "$BUNDLE_IDENTIFIER" ] \
        || release_fail "unexpected CFBundleIdentifier: $actual_bundle_identifier"

    actual_display_name=$(plist_value "$info_plist" CFBundleDisplayName) \
        || release_fail 'CFBundleDisplayName is missing from archived app'
    [ "$actual_display_name" = GhostTerm ] \
        || release_fail "unexpected CFBundleDisplayName: $actual_display_name"

    actual_bundle_name=$(plist_value "$info_plist" CFBundleName) \
        || release_fail 'CFBundleName is missing from archived app'
    [ "$actual_bundle_name" = GhostTerm ] \
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

    architectures=$("$lipo_path" -archs "$archive_app/Contents/MacOS/$PRODUCT_NAME") \
        || release_fail 'could not determine executable architectures'
    [ "$architectures" = arm64 ] \
        || release_fail "executable must contain arm64 only; found: $architectures"

    if [ -e "$archive_app/Contents/Frameworks/GhosttyKit.framework" ] \
        || [ -L "$archive_app/Contents/Frameworks/GhosttyKit.framework" ]; then
        release_fail 'GhosttyKit.framework must not be embedded; Ghostty is linked statically'
    fi

    linked_libraries=$("$otool_path" -L "$archive_app/Contents/MacOS/$PRODUCT_NAME") \
        || release_fail 'could not inspect executable linked libraries'
    if printf '%s\n' "$linked_libraries" | awk 'NR > 1 && $1 ~ /GhosttyKit[.]framework/ { found = 1 } END { exit found }'; then
        :
    else
        release_fail 'executable references GhosttyKit.framework instead of the static library'
    fi

    "$codesign_path" --verify --strict --verbose=4 "$archive_app" \
        || release_fail 'archived app did not pass strict code-signature verification'

    app_entitlements=$("$codesign_path" -d --entitlements :- "$archive_app" 2>/dev/null) \
        || release_fail 'could not read archived app entitlements'
    case "$app_entitlements" in
        *com.apple.security.get-task-allow*)
            release_fail 'archived app contains forbidden get-task-allow entitlement'
            ;;
    esac

    verify_signature_metadata "$archive_app" "$BUNDLE_IDENTIFIER" yes
}

stage_created=no
cleanup_stage() {
    cleanup_status=$?
    trap - 0 HUP INT TERM

    if [ "$stage_created" = yes ]; then
        if ! release_remove_generated_directory "$release_dir" "$stage_dir"; then
            printf 'error: could not remove generated staging directory: %s\n' "$stage_dir" >&2
        fi
    fi

    exit "$cleanup_status"
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

DEVELOPER_DIR=${DEVELOPER_DIR:-$DEFAULT_DEVELOPER_DIR}
[ -d "$DEVELOPER_DIR" ] || release_fail "DEVELOPER_DIR is not an existing directory: $DEVELOPER_DIR"
developer_dir_canonical=$(CDPATH= cd -P "$DEVELOPER_DIR" && pwd -P) \
    || release_fail "could not resolve DEVELOPER_DIR: $DEVELOPER_DIR"
DEVELOPER_DIR=$developer_dir_canonical
export DEVELOPER_DIR

require_command xcrun
require_command xcodegen
require_command ditto
require_command hdiutil
require_command codesign
require_command readlink
require_command awk
require_command git
[ -x /usr/libexec/PlistBuddy ] || release_fail 'required tool is not executable: /usr/libexec/PlistBuddy'

xcodebuild_path=$(xcrun --find xcodebuild 2>/dev/null) \
    || release_fail 'xcodebuild was not found in the selected DEVELOPER_DIR'
case "$xcodebuild_path" in
    "$DEVELOPER_DIR"/usr/bin/xcodebuild) ;;
    *) release_fail "selected DEVELOPER_DIR is not a full Xcode developer directory: $DEVELOPER_DIR" ;;
esac
lipo_path=$(xcrun --find lipo 2>/dev/null) \
    || release_fail 'lipo was not found in the selected DEVELOPER_DIR'
otool_path=$(xcrun --find otool 2>/dev/null) \
    || release_fail 'otool was not found in the selected DEVELOPER_DIR'
codesign_path=$(command -v codesign) || release_fail 'codesign was not found'
plist_buddy=/usr/libexec/PlistBuddy
xcodegen_path=$(command -v xcodegen) || release_fail 'xcodegen was not found'

release_dir=$(release_prepare_output_directory "$repo_root")
archive_path=$release_dir/$RELEASE_ARCHIVE_NAME
dmg_path=$release_dir/$RELEASE_DMG_NAME
stage_dir=$release_dir/$RELEASE_STAGE_NAME

printf '%s\n' 'cleanup: only prior GhostTerm archive, DMG, and staging directory under canonical .build/Release may be removed; unrelated files are preserved.'
release_remove_generated_directory "$release_dir" "$archive_path"
release_remove_generated_file "$release_dir" "$dmg_path"
release_remove_generated_directory "$release_dir" "$stage_dir"

source_revision=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null) \
    || release_fail 'could not determine source revision'
printf 'Source revision (working tree cleanliness is not required): %s\n' "$source_revision"

cd "$repo_root"
"$script_dir/build-ghostty.sh"
"$xcodegen_path" generate --spec "$repo_root/project.yml"
"$xcodebuild_path" archive \
    -project "$repo_root/GhostTerm.xcodeproj" \
    -scheme GhostTerm \
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

trap cleanup_stage 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$stage_dir" || release_fail "could not create staging directory: $stage_dir"
stage_created=yes
"$(command -v ditto)" "$archive_app" "$stage_dir/$PRODUCT_NAME.app"
ln -s /Applications "$stage_dir/Applications" \
    || release_fail 'could not create Applications symlink in staging directory'
[ -L "$stage_dir/Applications" ] || release_fail 'Applications staging entry is not a symlink'
[ "$(readlink "$stage_dir/Applications")" = /Applications ] \
    || release_fail 'Applications staging symlink does not target /Applications'
"$codesign_path" --verify --strict --verbose=4 "$stage_dir/$PRODUCT_NAME.app" \
    || release_fail 'staged app did not preserve its strict code signature'

hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$stage_dir" \
    -ov \
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
printf '%s\n' ".build/Release/$RELEASE_DMG_NAME"
