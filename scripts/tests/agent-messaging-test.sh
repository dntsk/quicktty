#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
repo_root=$(CDPATH= cd -P "$script_dir/../.." && pwd -P)
tmp_base=$(CDPATH= cd -P "${TMPDIR:-/tmp}" && pwd -P)
test_root=

cleanup() {
    status=$?
    trap - 0 HUP INT TERM
    case "${test_root:-}" in
        "$tmp_base"/quicktty-messaging-test.*)
            [ ! -L "$test_root" ] && [ -d "$test_root" ] && /bin/rm -rf "$test_root"
            ;;
        "") ;;
        *) printf 'FAIL: refusing to remove unexpected test path\n' >&2 ;;
    esac
    exit "$status"
}

trap cleanup 0 HUP INT TERM
test_root=$(/usr/bin/mktemp -d "$tmp_base/quicktty-messaging-test.XXXXXX")
case "${1:-}" in
    --pi-e2e)
        [ "$#" -eq 3 ] || { printf 'FAIL: expected Pi node/package paths\n' >&2; exit 1; }
        ;;
    "") [ "$#" -eq 0 ] || exit 1 ;;
    *) printf 'FAIL: unknown messaging contract mode\n' >&2; exit 1 ;;
esac
/bin/mkdir "$test_root/unverified"
/usr/bin/xcrun clang "$script_dir/fixtures/agent-messaging-unverified-claude.c" -o "$test_root/unverified/claude"
/usr/bin/xcrun --sdk macosx swiftc \
    -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    "$repo_root"/Shared/AgentIntegrations/*.swift \
    "$repo_root"/Shared/AgentIntegrations/Installer/*.swift \
    "$repo_root"/Shared/AgentIntegrations/TerminalControl/*.swift \
    "$repo_root"/QuickTTYCLI/*.swift -o "$test_root/quicktty"
/usr/bin/xcrun --sdk macosx swiftc \
    -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
    "$repo_root"/QuickTTY/AgentIntegrations/Messaging/*.swift \
    "$repo_root"/Shared/AgentIntegrations/*.swift \
    "$repo_root"/Shared/AgentIntegrations/Installer/*.swift \
    "$repo_root"/Shared/AgentIntegrations/TerminalControl/*.swift \
    "$repo_root"/QuickTTY/AgentIntegrations/IPC/AuthenticatedLocalSocketServer.swift \
    "$repo_root"/QuickTTY/AgentIntegrations/IPC/AgentMessagingSocketServer.swift \
    "$repo_root"/QuickTTY/AgentIntegrations/IPC/AgentSocketServer.swift \
    "$repo_root"/QuickTTY/Domain/*.swift \
    "$repo_root"/QuickTTY/Presentation/Splits/SplitCommand.swift \
    "$repo_root"/QuickTTY/AgentIntegrations/AgentSessionController.swift \
    "$repo_root"/QuickTTY/AgentIntegrations/AgentMessagingService.swift \
    "$repo_root"/QuickTTY/AgentIntegrations/AgentIntegrationDefinition.swift \
    "$repo_root"/QuickTTY/AgentIntegrations/AgentIntegrationRegistry.swift \
    "$repo_root"/QuickTTY/AgentIntegrations/ExecutableInvocation.swift \
    "$repo_root"/QuickTTY/AgentIntegrations/Adapters/*.swift \
    "$script_dir/fixtures/agent-messaging-contract.swift" \
    "$script_dir/fixtures/agent-messaging-runtime-contract.swift" \
    "$script_dir/fixtures/agent-messaging-autoconnect-contract.swift" \
    "$script_dir/fixtures/agent-messaging-ipc-contract.swift" \
    "$script_dir/fixtures/agent-messaging-host-contract.swift" \
    "$script_dir/fixtures/agent-messaging-installer-contract.swift" \
    "$script_dir/fixtures/agent-messaging-claude-question-contract.swift" \
    "$script_dir/fixtures/agent-messaging-claude-cli-contract.swift" \
    "$script_dir/fixtures/agent-messaging-pi-e2e-contract.swift" \
    -o "$test_root/agent-messaging-contract"
/usr/bin/python3 - "$test_root/agent-messaging-contract" "$repo_root" "$test_root" "$@" <<'PY'
import os
import signal
import subprocess
import sys

binary, repo, root, *options = sys.argv[1:]
command = [binary, repo, root]
if options:
    mode, node, package = options
    command = [binary, mode, repo, root, node, package, root + "/quicktty"]
process = subprocess.Popen(command, start_new_session=True)
try:
    result = process.wait(timeout=45 if options else 30)
except subprocess.TimeoutExpired:
    # The unreaped leader keeps this process group owned by the fixture.
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    raise SystemExit("FAIL: messaging contract timed out")
if result:
    raise SystemExit(result)
PY
