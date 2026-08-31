#!/bin/sh
set -eu

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

assert_file_equals() {
    /usr/bin/cmp -s "$1" "$2" || fail "files differ: $1 and $2"
}

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P) || fail 'could not resolve test directory'
repo_root=$(CDPATH= cd -P "$script_dir/../.." && pwd -P) || fail 'could not resolve repository root'
resource_dir=$repo_root/QuickTTY/Resources/AgentIntegrations
session_resource_dir=$repo_root/QuickTTY/Resources/AgentSessionIntegrations
helper=$resource_dir/quicktty-progress
claude_example=$resource_dir/claude-settings.example.json
codex_example=$resource_dir/codex-hooks.example.json
project_spec=$repo_root/project.yml
documentation=$repo_root/docs/agent-integrations.md
usage='usage: quicktty-progress claude|codex working|waiting|failed|completed'
helper_path='/Applications/QuickTTY.app/Contents/Resources/AgentIntegrations/quicktty-progress'
python_path=/usr/bin/python3

[ -x "$helper" ] || fail "helper is missing or not executable: $helper"
[ -f "$claude_example" ] || fail "Claude example is missing: $claude_example"
[ -f "$codex_example" ] || fail "Codex example is missing: $codex_example"
[ -f "$project_spec" ] || fail "project spec is missing: $project_spec"
[ -f "$documentation" ] || fail "agent integration documentation is missing: $documentation"
[ -x "$python_path" ] || fail "system Python is unavailable: $python_path"

/usr/bin/grep -F '/settings' "$documentation" >/dev/null \
    || fail 'Pi documentation does not mention /settings'
/usr/bin/grep -F 'Terminal progress' "$documentation" >/dev/null \
    || fail 'Pi documentation does not mention Terminal progress'
/usr/bin/grep -F 'terminal.showTerminalProgress' "$documentation" >/dev/null \
    || fail 'Pi documentation does not mention terminal.showTerminalProgress'

sh -n "$helper"
sh -n "$0"
"$python_path" -m json.tool "$claude_example" >/dev/null
"$python_path" -m json.tool "$codex_example" >/dev/null

case "$(LC_ALL=C /usr/bin/grep -Eic '(^|[^[:alpha:]])(cat|read)([^[:alpha:]]|$)|stdin|transcript|prompt|secret|api[_-]?key|token|password' "$helper")" in
    0) ;;
    *) fail 'helper must not inspect input, conversation data, or secrets' ;;
esac

TMPDIR=${TMPDIR:-/tmp}
tmp_base=$(CDPATH= cd -P "$TMPDIR" && pwd -P) || fail "could not resolve temporary directory base: $TMPDIR"
[ -n "$tmp_base" ] && [ "$tmp_base" != / ] || fail 'temporary directory base must not be empty or /'
tmp_root=

cleanup() {
    status=$?
    trap - 0 HUP INT TERM

    if [ -n "$tmp_root" ] && [ -d "$tmp_root" ]; then
        case "$tmp_root" in
            "$tmp_base"/quicktty-agent-integrations-test.*) /bin/rm -rf "$tmp_root" ;;
            *) printf 'error: refusing to remove unexpected temporary path: %s\n' "$tmp_root" >&2 ;;
        esac
    fi

    exit "$status"
}

trap cleanup 0 HUP INT TERM
tmp_root=$(/usr/bin/mktemp -d "$tmp_base/quicktty-agent-integrations-test.XXXXXX") \
    || fail 'could not create temporary directory'
case "$tmp_root" in
    "$tmp_base"/quicktty-agent-integrations-test.*) ;;
    *) fail "temporary directory has an unexpected path: $tmp_root" ;;
esac

expected_usage=$tmp_root/expected-usage
printf '%s\n' "$usage" >"$expected_usage"

expect_invalid() {
    invalid_stdout=$tmp_root/invalid-stdout
    invalid_stderr=$tmp_root/invalid-stderr

    if "$helper" "$@" >"$invalid_stdout" 2>"$invalid_stderr"; then
        fail "invalid helper invocation succeeded: $*"
    fi
    [ ! -s "$invalid_stdout" ] || fail "invalid helper invocation wrote stdout: $*"
    assert_file_equals "$expected_usage" "$invalid_stderr"
}

expect_invalid
expect_invalid claude
expect_invalid unknown working
expect_invalid claude unknown
expect_invalid codex completed extra
expect_invalid Claude working

progress_number() {
    case "$1" in
        working) printf '3\n' ;;
        waiting) printf '4\n' ;;
        failed) printf '2\n' ;;
        completed) printf '0\n' ;;
        *) fail "unexpected test state: $1" ;;
    esac
}

for state in working waiting failed completed; do
    number=$(progress_number "$state")
    actual_json=$tmp_root/claude-$state.json
    expected_json=$tmp_root/claude-$state-expected.json
    actual_sequence=$tmp_root/claude-$state.sequence
    expected_sequence=$tmp_root/claude-$state-expected.sequence

    "$helper" claude "$state" >"$actual_json"
    printf '{"terminalSequence":"\\u001b]9;4;%s\\u0007"}\n' "$number" >"$expected_json"
    assert_file_equals "$expected_json" "$actual_json"
    "$python_path" -m json.tool "$actual_json" >/dev/null
    /usr/bin/plutil -extract terminalSequence raw -o "$actual_sequence" "$actual_json"
    printf '\033]9;4;%s\007' "$number" >"$expected_sequence"
    assert_file_equals "$expected_sequence" "$actual_sequence"
done

for state in working waiting failed completed; do
    number=$(progress_number "$state")
    tty_output=$tmp_root/codex-$state.tty
    hook_stdout=$tmp_root/codex-$state.stdout
    expected_tty=$tmp_root/codex-$state-expected.tty
    expected_stdout=$tmp_root/codex-$state-expected.stdout

    "$python_path" - "$helper" "$state" "$tty_output" "$hook_stdout" <<'PY'
import os
import pty
import sys

helper, state, tty_path, stdout_path = sys.argv[1:]
pid, master = pty.fork()
if pid == 0:
    output = os.open(stdout_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.dup2(output, 1)
    os.close(output)
    os.execv(helper, [helper, "codex", state])

chunks = []
while True:
    try:
        chunk = os.read(master, 4096)
    except OSError:
        break
    if not chunk:
        break
    chunks.append(chunk)
os.close(master)
_, status = os.waitpid(pid, 0)
if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
    raise SystemExit("codex helper failed under pseudo-TTY")
with open(tty_path, "wb") as output:
    output.write(b"".join(chunks))
PY

    printf '\033]9;4;%s\007' "$number" >"$expected_tty"
    printf '{}\n' >"$expected_stdout"
    assert_file_equals "$expected_tty" "$tty_output"
    assert_file_equals "$expected_stdout" "$hook_stdout"
    "$python_path" -m json.tool "$hook_stdout" >/dev/null
done

missing_stdout=$tmp_root/codex-missing-tty.stdout
missing_stderr=$tmp_root/codex-missing-tty.stderr
"$python_path" - "$helper" "$missing_stdout" "$missing_stderr" <<'PY'
import subprocess
import sys

helper, stdout_path, stderr_path = sys.argv[1:]
result = subprocess.run(
    [helper, "codex", "working"],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    start_new_session=True,
    check=False,
)
with open(stdout_path, "wb") as output:
    output.write(result.stdout)
with open(stderr_path, "wb") as output:
    output.write(result.stderr)
if result.returncode != 0:
    raise SystemExit("codex helper failed without a controlling TTY")
PY
printf '{}\n' >"$tmp_root/codex-missing-tty-expected.stdout"
assert_file_equals "$tmp_root/codex-missing-tty-expected.stdout" "$missing_stdout"
[ ! -s "$missing_stderr" ] || fail 'codex helper wrote stderr without a controlling TTY'
"$python_path" -m json.tool "$missing_stdout" >/dev/null

assert_hook() {
    hook_file=$1
    event=$2
    mode=$3
    state=$4
    expected_command="\"$helper_path\" $mode $state"

    [ "$(/usr/bin/plutil -extract "hooks.$event" raw -o - "$hook_file")" = 1 ] \
        || fail "$event must have exactly one hook group"
    [ "$(/usr/bin/plutil -extract "hooks.$event.0.hooks" raw -o - "$hook_file")" = 1 ] \
        || fail "$event must have exactly one command hook"
    [ "$(/usr/bin/plutil -extract "hooks.$event.0.hooks.0.type" raw -o - "$hook_file")" = command ] \
        || fail "$event hook type is not command"
    [ "$(/usr/bin/plutil -extract "hooks.$event.0.hooks.0.command" raw -o - "$hook_file")" = "$expected_command" ] \
        || fail "$event has an unexpected helper command"
}

assert_hook "$claude_example" UserPromptSubmit claude working
assert_hook "$claude_example" PermissionRequest claude waiting
assert_hook "$claude_example" Notification claude waiting
assert_hook "$claude_example" PostToolUse claude working
assert_hook "$claude_example" PostToolUseFailure claude working
assert_hook "$claude_example" Stop claude completed
assert_hook "$claude_example" StopFailure claude failed
assert_hook "$claude_example" SessionEnd claude completed
[ "$(/usr/bin/plutil -extract hooks.Notification.0.matcher raw -o - "$claude_example")" = \
    'permission_prompt|idle_prompt|agent_needs_input' ] \
    || fail 'Claude Notification matcher is incorrect'

assert_hook "$codex_example" UserPromptSubmit codex working
assert_hook "$codex_example" PermissionRequest codex waiting
assert_hook "$codex_example" PostToolUse codex working
assert_hook "$codex_example" Stop codex completed
assert_hook "$codex_example" SessionEnd codex completed

/usr/bin/plutil -extract hooks raw -o - "$claude_example" | LC_ALL=C /usr/bin/sort >"$tmp_root/claude-events"
printf '%s\n' Notification PermissionRequest PostToolUse PostToolUseFailure SessionEnd Stop StopFailure UserPromptSubmit \
    | LC_ALL=C /usr/bin/sort >"$tmp_root/claude-events-expected"
assert_file_equals "$tmp_root/claude-events-expected" "$tmp_root/claude-events"

/usr/bin/plutil -extract hooks raw -o - "$codex_example" | LC_ALL=C /usr/bin/sort >"$tmp_root/codex-events"
printf '%s\n' PermissionRequest PostToolUse SessionEnd Stop UserPromptSubmit \
    | LC_ALL=C /usr/bin/sort >"$tmp_root/codex-events-expected"
assert_file_equals "$tmp_root/codex-events-expected" "$tmp_root/codex-events"

/usr/bin/grep -F -x '          - AgentIntegrations' "$project_spec" >/dev/null \
    || fail 'project resources do not exclude AgentIntegrations from the flattened resource entry'
/usr/bin/grep -F -x '      - path: QuickTTY/Resources/AgentIntegrations' "$project_spec" >/dev/null \
    || fail 'project resources do not include AgentIntegrations explicitly'
/usr/bin/grep -F -x '        type: folder' "$project_spec" >/dev/null \
    || fail 'AgentIntegrations is not configured as a folder resource'
/usr/bin/grep -F -x '          - AgentSessionIntegrations' "$project_spec" >/dev/null \
    || fail 'native lifecycle resources are not excluded from the flattened resource entry'
/usr/bin/grep -F -x '      - path: QuickTTY/Resources/AgentSessionIntegrations' "$project_spec" >/dev/null \
    || fail 'native lifecycle resources are not included explicitly'

expected_native_ids='claude codex pi omp cursor gemini hermes copilot droid qoder kimi'
expected_wrapper_ids='amp antigravity opencode'
for adapter_id in $expected_native_ids $expected_wrapper_ids; do
    manifest=$session_resource_dir/$adapter_id/integration.json
    [ -f "$manifest" ] || fail "native lifecycle manifest is missing: $adapter_id"
    "$python_path" -m json.tool "$manifest" >/dev/null
    [ "$(/usr/bin/plutil -extract adapter raw -o - "$manifest")" = "$adapter_id" ] \
        || fail "native lifecycle manifest has the wrong adapter: $adapter_id"
done
[ "$(/usr/bin/find "$session_resource_dir" -mindepth 1 -maxdepth 1 -type d | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 14 ] \
    || fail 'agent lifecycle resource directory set is not exact'
if LC_ALL=C /usr/bin/grep -R -n '[^ -~]' "$session_resource_dir" >/dev/null; then
    fail 'agent lifecycle resources must contain English ASCII only'
fi
if LC_ALL=C /usr/bin/grep -R -Ei 'api[_-]?key|password|credential|bearer[[:space:]]|private[_-]?key' "$session_resource_dir" >/dev/null; then
    fail 'agent lifecycle resources must not contain credentials'
fi

printf 'Agent integration contract tests passed.\n'
