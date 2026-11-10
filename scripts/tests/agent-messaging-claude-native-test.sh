#!/bin/sh
set -eu

[ "$#" -eq 2 ] || { printf 'Usage: %s <verified-Claude-2.1.318-binary> <SDK-0.3.318-package-directory>\n' "$0" >&2; exit 2; }
script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
repo_root=$(CDPATH= cd -P "$script_dir/../.." && pwd -P)
node_path=$(command -v node) || { printf 'FAIL: Node.js unavailable\n' >&2; exit 1; }
[ -x "$1" ] && [ -f "$2/sdk.mjs" ] || { printf 'FAIL: native CLI/SDK artifacts unavailable; nothing is installed automatically\n' >&2; exit 1; }
test_root=$(/usr/bin/mktemp -d /tmp/quicktty-claude-native-test.XXXXXX)
cleanup() {
    status=$?
    trap - 0 HUP INT TERM
    case "$test_root" in
        /tmp/quicktty-claude-native-test.*)
            [ ! -L "$test_root" ] && [ -d "$test_root" ] && /bin/rm -rf "$test_root"
            ;;
        *) printf 'FAIL: refusing unexpected cleanup path\n' >&2 ;;
    esac
    exit "$status"
}
trap cleanup 0 HUP INT TERM
umask 077
/bin/mkdir "$test_root/bin"
/usr/bin/xcrun clang "$script_dir/fixtures/agent-messaging-empty-security.c" -o "$test_root/bin/security"
/usr/bin/xcrun clang "$script_dir/fixtures/agent-messaging-privacy-probe.c" -o "$test_root/privacy-probe"
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
    "$script_dir/fixtures/agent-messaging-claude-native-host.swift" -o "$test_root/native-host"
/usr/bin/python3 "$script_dir/fixtures/agent-messaging-claude-native-contract.py" \
    "$test_root" "$1" "$2" "$node_path" "$script_dir/fixtures/agent-messaging-claude-native-sdk.mjs"
