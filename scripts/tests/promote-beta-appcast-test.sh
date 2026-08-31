#!/bin/sh
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
export PATH

set -eu

LC_ALL=C
export LC_ALL

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

assert_equals() {
    [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        fail "expected command to fail: $*"
    fi
}

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P) || fail 'could not resolve test directory'
repo_root=$(CDPATH= cd -P "$script_dir/../.." && pwd -P) || fail 'could not resolve repository root'
promotion_script=$repo_root/scripts/promote-beta-appcast.sh
release_helpers=$repo_root/scripts/release-helpers.sh
makefile=$repo_root/Makefile
runbook=$repo_root/docs/releasing.md
agents=$repo_root/AGENTS.md
readme=$repo_root/README.md

[ -f "$promotion_script" ] || fail "beta appcast promotion script is missing: $promotion_script"
[ -f "$release_helpers" ] || fail "release helpers are missing: $release_helpers"
[ -f "$makefile" ] || fail "Makefile is missing: $makefile"
[ -f "$runbook" ] || fail "release runbook is missing: $runbook"
[ -f "$agents" ] || fail "agent instructions are missing: $agents"
[ -f "$readme" ] || fail "README is missing: $readme"
sh -n "$promotion_script"
grep -F -x 'PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin' "$promotion_script" >/dev/null \
    || fail 'beta appcast promotion script does not set the trusted PATH'
grep -F -x 'beta-feed:' "$makefile" >/dev/null \
    || fail 'Makefile is missing beta-feed target'
grep -F -x 'beta-feed-contract:' "$makefile" >/dev/null \
    || fail 'Makefile is missing beta-feed-contract target'
grep -F 'Продвижение beta channel' "$runbook" >/dev/null \
    || fail 'release runbook does not define beta channel promotion'
grep -F 'https://raw.githubusercontent.com/dntsk/quicktty/master/docs/appcasts/beta.xml' "$runbook" >/dev/null \
    || fail 'release runbook does not define the public beta appcast URL'
grep -F 'make beta-feed' "$runbook" >/dev/null \
    || fail 'release runbook does not require beta appcast promotion'
grep -F 'legacy bootstrap' "$runbook" >/dev/null \
    || fail 'release runbook does not define the immutable legacy bootstrap'
grep -F 'docs/appcasts/beta.xml' "$agents" >/dev/null \
    || fail 'agent instructions do not require beta appcast promotion'
grep -F 'docs/appcasts/beta.xml' "$readme" >/dev/null \
    || fail 'README does not document beta appcast promotion'
for policy_file in "$runbook" "$agents"; do
    grep -F 'надмножеством' "$policy_file" >/dev/null \
        || fail "release policy does not define beta as a superset of stable: $policy_file"
done
grep -F 'superset of stable' "$readme" >/dev/null \
    || fail 'README does not define beta as a superset of stable'
grep -F 'после stable release предыдущий beta build' "$runbook" >/dev/null \
    || fail 'release runbook does not require beta-to-stable update smoke'

TMPDIR=${TMPDIR:-/tmp}
tmp_base=$(CDPATH= cd -P "$TMPDIR" && pwd -P) || fail "could not resolve temporary directory base: $TMPDIR"
tmp_root=

cleanup() {
    cleanup_status=$?
    trap - 0 HUP INT TERM

    if [ -n "$tmp_root" ] && [ -d "$tmp_root" ]; then
        case "$tmp_root" in
            "$tmp_base"/quicktty-beta-feed-test.*) /bin/rm -rf "$tmp_root" ;;
            *) printf 'error: refusing to remove unexpected temporary path: %s\n' "$tmp_root" >&2 ;;
        esac
    fi

    exit "$cleanup_status"
}

trap cleanup 0 HUP INT TERM
tmp_root=$(/usr/bin/mktemp -d "$tmp_base/quicktty-beta-feed-test.XXXXXX") \
    || fail 'could not create temporary directory'
fixture_repo=$tmp_root/repository
/bin/mkdir -p "$fixture_repo/scripts" "$fixture_repo/docs/appcasts" \
    "$fixture_repo/.build/Release/appcast"
/bin/cp "$promotion_script" "$fixture_repo/scripts/promote-beta-appcast.sh"
/bin/cp "$release_helpers" "$fixture_repo/scripts/release-helpers.sh"
/bin/chmod +x "$fixture_repo/scripts/promote-beta-appcast.sh"

. "$release_helpers"
fixture_dmg=$fixture_repo/.build/Release/$RELEASE_DMG_NAME
fixture_appcast=$fixture_repo/.build/Release/appcast/$RELEASE_APPCAST_NAME
fixture_target=$fixture_repo/$RELEASE_BETA_APPCAST_RELATIVE_PATH
printf 'final DMG\n' >"$fixture_dmg"
fixture_size=$(/usr/bin/stat -f '%z' "$fixture_dmg")
printf '<enclosure url="%s%s" sparkle:edSignature="fixture" length="%s" type="application/octet-stream"/>\n' \
    "$(release_appcast_download_url_prefix)" "$RELEASE_DMG_NAME" "$fixture_size" >"$fixture_appcast"
printf 'previous beta appcast\n' >"$fixture_target"
printf '.build/\n' >"$fixture_repo/.gitignore"

/usr/bin/git -C "$fixture_repo" init -q
/usr/bin/git -C "$fixture_repo" add .gitignore docs scripts
/usr/bin/git -C "$fixture_repo" -c user.name=QuickTTY -c user.email=release-test@example.invalid \
    commit -qm 'fixture'

expect_failure /bin/sh "$fixture_repo/scripts/promote-beta-appcast.sh" unexpected-option
printf 'dirty\n' >>"$fixture_target"
expect_failure /bin/sh "$fixture_repo/scripts/promote-beta-appcast.sh"
/usr/bin/git -C "$fixture_repo" checkout -- docs/appcasts/beta.xml

/bin/sh "$fixture_repo/scripts/promote-beta-appcast.sh"
cmp -s "$fixture_appcast" "$fixture_target" || fail 'promotion did not copy the final appcast exactly'

printf '<enclosure url="bad" length="0" type="application/octet-stream"/>\n' >"$fixture_appcast"
expect_failure /bin/sh "$fixture_repo/scripts/promote-beta-appcast.sh"

printf 'QuickTTY beta appcast promotion contract tests passed.\n'
