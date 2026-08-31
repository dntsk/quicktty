#!/bin/sh
set -eu

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
repo_root=$(CDPATH= cd -P "$script_dir/../.." && pwd -P)
TMPDIR=${TMPDIR:-/tmp}
tmp_base=$(CDPATH= cd -P "$TMPDIR" && pwd -P)
test_root=

cleanup() {
    status=$?
    trap - 0 HUP INT TERM
    case "${test_root:-}" in
        "$tmp_base"/quicktty-launch-test.*)
            [ ! -L "$test_root" ] && [ -d "$test_root" ] && /bin/rm -rf "$test_root"
            ;;
        "") ;;
        *) printf 'FAIL: refusing to remove unexpected test path: %s\n' "$test_root" >&2 ;;
    esac
    exit "$status"
}

trap cleanup 0 HUP INT TERM
test_root=$(/usr/bin/mktemp -d "$tmp_base/quicktty-launch-test.XXXXXX")
case "$test_root" in
    "$tmp_base"/quicktty-launch-test.*) ;;
    *) fail "temporary root has an unexpected path: $test_root" ;;
esac

helper_dir="$test_root/Helper's Directory"
helper="$helper_dir/quicktty"
recorder_source_dir=$test_root/recorder-source
recorder="$test_root/fake argv recorder"
working_directory="$test_root/Working Directory"
record=$test_root/argv.record
marker_one=$test_root/command-substitution-ran
marker_two=$test_root/semicolon-ran
/bin/mkdir -p "$helper_dir" "$recorder_source_dir" "$working_directory"

/usr/bin/xcrun --sdk macosx swiftc \
    "$repo_root"/Shared/AgentIntegrations/*.swift \
    "$repo_root"/Shared/AgentIntegrations/Installer/*.swift \
    "$repo_root"/QuickTTYCLI/*.swift \
    -o "$helper"

cat >"$recorder_source_dir/main.swift" <<'SWIFT'
import Foundation

private let environmentKeys = [
    "QUICKTTY_PANE_ID",
    "QUICKTTY_AGENT_SOCKET",
    "QUICKTTY_INSTANCE_ID",
    "QUICKTTY_PANE_TOKEN",
    "QUICKTTY_LAUNCH_PAYLOAD",
    "QUICKTTY_AGENT_HELPER",
]

private func appendLength(_ value: UInt32, to data: inout Data) {
    var value = value.bigEndian
    Swift.withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

private func append(_ value: String?, to data: inout Data) {
    guard let value else {
        appendLength(UInt32.max, to: &data)
        return
    }
    let bytes = Data(value.utf8)
    appendLength(UInt32(bytes.count), to: &data)
    data.append(bytes)
}

guard let recordPath = ProcessInfo.processInfo.environment["QUICKTTY_TEST_RECORD_PATH"] else {
    exit(90)
}

var record = Data()
appendLength(UInt32(CommandLine.arguments.count), to: &record)
for argument in CommandLine.arguments {
    append(argument, to: &record)
}
append(FileManager.default.currentDirectoryPath, to: &record)
for key in environmentKeys {
    append(ProcessInfo.processInfo.environment[key], to: &record)
}
try record.write(to: URL(fileURLWithPath: recordPath), options: .atomic)
SWIFT

/usr/bin/xcrun --sdk macosx swiftc "$recorder_source_dir/main.swift" -o "$recorder"

noncanonical_payload_file=$test_root/noncanonical-payload
payload=$(/usr/bin/python3 - "$recorder" "$working_directory" "$marker_one" "$marker_two" \
    "$noncanonical_payload_file" <<'PY'
import base64
import json
import sys

executable, cwd, marker_one, marker_two, noncanonical_path = sys.argv[1:]
arguments = [
    "space value",
    "single'quote",
    'double"quote',
    "$(touch " + marker_one + ")",
    "; touch " + marker_two,
    "line one\nline two",
    "",
    "猫 Привет 👩🏽‍💻",
]
payload = {
    "arguments": arguments,
    "executable": executable,
    "workingDirectory": cwd,
}
canonical = json.dumps(
    payload,
    ensure_ascii=False,
    separators=(",", ":"),
    sort_keys=True,
).encode("utf-8")
noncanonical = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
with open(noncanonical_path, "wb") as output:
    output.write(base64.b64encode(noncanonical))
sys.stdout.write(base64.b64encode(canonical).decode("ascii"))
PY
)

/usr/bin/env \
    QUICKTTY_LAUNCH_PAYLOAD="$payload" \
    QUICKTTY_AGENT_HELPER="$helper" \
    QUICKTTY_PANE_ID='pane-id' \
    QUICKTTY_AGENT_SOCKET="$test_root/agent.sock" \
    QUICKTTY_INSTANCE_ID='instance-id' \
    QUICKTTY_PANE_TOKEN='pane-token' \
    QUICKTTY_TEST_RECORD_PATH="$record" \
    "$helper" internal launch

[ -f "$record" ] || fail 'target recorder did not execute'
[ ! -e "$marker_one" ] || fail 'command substitution argument was executed by a shell'
[ ! -e "$marker_two" ] || fail 'semicolon argument was executed by a shell'

/usr/bin/python3 - "$record" "$recorder" "$working_directory" "$marker_one" "$marker_two" \
    "$test_root/agent.sock" <<'PY'
import struct
import sys

record_path, executable, cwd, marker_one, marker_two, socket_path = sys.argv[1:]
expected_arguments = [
    executable,
    "space value",
    "single'quote",
    'double"quote',
    "$(touch " + marker_one + ")",
    "; touch " + marker_two,
    "line one\nline two",
    "",
    "猫 Привет 👩🏽‍💻",
]
expected_environment = [
    "pane-id",
    socket_path,
    "instance-id",
    "pane-token",
    None,
    None,
]
data = open(record_path, "rb").read()
offset = 0

def read_length():
    global offset
    if offset + 4 > len(data):
        raise SystemExit("truncated record length")
    value = struct.unpack(">I", data[offset:offset + 4])[0]
    offset += 4
    return value

def read_value():
    global offset
    length = read_length()
    if length == 0xFFFFFFFF:
        return None
    if offset + length > len(data):
        raise SystemExit("truncated record value")
    value = data[offset:offset + length]
    offset += length
    return value.decode("utf-8")

argument_count = read_length()
actual_arguments = [read_value() for _ in range(argument_count)]
actual_cwd = read_value()
actual_environment = [read_value() for _ in expected_environment]
if offset != len(data):
    raise SystemExit("record contains trailing bytes")
if actual_arguments != expected_arguments:
    raise SystemExit(f"argv mismatch: {actual_arguments!r}")
if actual_cwd != cwd:
    raise SystemExit(f"cwd mismatch: {actual_cwd!r}")
if actual_environment != expected_environment:
    raise SystemExit(f"environment mismatch: {actual_environment!r}")
PY

expected_error=$test_root/expected-error
printf 'quicktty: internal launch failed\n' >"$expected_error"

expect_rejected() {
    name=$1
    payload_mode=$2
    rejected_record=$test_root/$name.record
    stdout=$test_root/$name.stdout
    stderr=$test_root/$name.stderr
    /bin/rm -f "$rejected_record"

    set +e
    if [ "$payload_mode" = missing ]; then
        /usr/bin/env -u QUICKTTY_LAUNCH_PAYLOAD \
            QUICKTTY_AGENT_HELPER="$helper" \
            QUICKTTY_TEST_RECORD_PATH="$rejected_record" \
            "$helper" internal launch >"$stdout" 2>"$stderr"
    else
        /usr/bin/env \
            QUICKTTY_LAUNCH_PAYLOAD="$payload_mode" \
            QUICKTTY_AGENT_HELPER="$helper" \
            QUICKTTY_TEST_RECORD_PATH="$rejected_record" \
            "$helper" internal launch >"$stdout" 2>"$stderr"
    fi
    status=$?
    set -e

    [ "$status" -ne 0 ] || fail "$name payload unexpectedly succeeded"
    [ ! -e "$rejected_record" ] || fail "$name payload executed the target"
    [ ! -s "$stdout" ] || fail "$name payload wrote stdout"
    /usr/bin/cmp -s "$expected_error" "$stderr" || fail "$name payload exposed unexpected stderr"
    [ "$(/usr/bin/stat -f '%z' "$stderr")" -le 128 ] || fail "$name stderr is unbounded"
}

expect_rejected missing missing
expect_rejected malformed '!!!!'
noncanonical_payload=$(/bin/cat "$noncanonical_payload_file")
expect_rejected noncanonical "$noncanonical_payload"
oversized_payload=$(/usr/bin/python3 - <<'PY'
import sys
sys.stdout.write("A" * 87385)
PY
)
expect_rejected oversized "$oversized_payload"

hook_instance_id=11111111-1111-1111-1111-111111111111
hook_pane_id=22222222-2222-2222-2222-222222222222
hook_pane_token=abababababababababababababababababababababababababababababababab
hook_socket=$test_root/hook.sock

assert_hook_rejected() {
    name=$1
    status=$2
    stdout=$3
    stderr=$4

    [ "$status" -ne 0 ] || fail "$name hook fixture unexpectedly succeeded"
    [ ! -s "$stdout" ] || fail "$name hook fixture wrote stdout"
    [ ! -s "$stderr" ] || fail "$name hook fixture wrote stderr"
}

run_hook_rejected() {
    name=$1
    event=$2
    input=$3
    stdout=$test_root/hook-$name.stdout
    stderr=$test_root/hook-$name.stderr

    set +e
    /usr/bin/env \
        QUICKTTY_INSTANCE_ID="$hook_instance_id" \
        QUICKTTY_PANE_ID="$hook_pane_id" \
        QUICKTTY_PANE_TOKEN="$hook_pane_token" \
        QUICKTTY_AGENT_SOCKET="$hook_socket" \
        "$helper" internal hook claude "$event" <"$input" >"$stdout" 2>"$stderr"
    status=$?
    set -e
    assert_hook_rejected "$name" "$status" "$stdout" "$stderr"
}

printf '{' >"$test_root/hook-malformed.input"
printf '{"cwd":"/tmp","session_id":"session"}' >"$test_root/hook-unrelated.input"
/usr/bin/python3 - "$test_root/hook-oversized.input" <<'PY'
import sys

with open(sys.argv[1], "wb") as output:
    output.write(b" " * 65537)
PY
run_hook_rejected malformed SessionStart "$test_root/hook-malformed.input"
run_hook_rejected oversized SessionStart "$test_root/hook-oversized.input"
run_hook_rejected unrelated BeforeToolUse "$test_root/hook-unrelated.input"

ipc_stdout=$test_root/hook-ipc-reject.stdout
ipc_stderr=$test_root/hook-ipc-reject.stderr
ipc_status=$test_root/hook-ipc-reject.status
/usr/bin/python3 - "$helper" "$hook_socket" "$ipc_stdout" "$ipc_stderr" "$ipc_status" <<'PY'
import os
import socket
import subprocess
import sys

helper, socket_path, stdout_path, stderr_path, status_path = sys.argv[1:]
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(socket_path)
server.listen(1)
environment = os.environ.copy()
environment.update(
    {
        "QUICKTTY_INSTANCE_ID": "11111111-1111-1111-1111-111111111111",
        "QUICKTTY_PANE_ID": "22222222-2222-2222-2222-222222222222",
        "QUICKTTY_PANE_TOKEN": "ab" * 32,
        "QUICKTTY_AGENT_SOCKET": socket_path,
    }
)
process = subprocess.Popen(
    [helper, "internal", "hook", "claude", "SessionStart"],
    env=environment,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
process.stdin.write(b'{"cwd":"/tmp","session_id":"session"}')
process.stdin.close()
process.stdin = None
connection, _ = server.accept()
try:
    connection.sendall(b"\x00")
except BrokenPipeError:
    pass
connection.close()
server.close()
stdout, stderr = process.communicate()
with open(stdout_path, "wb") as output:
    output.write(stdout)
with open(stderr_path, "wb") as output:
    output.write(stderr)
with open(status_path, "w", encoding="ascii") as output:
    output.write(str(process.returncode))
PY
assert_hook_rejected ipc-reject "$(/bin/cat "$ipc_status")" "$ipc_stdout" "$ipc_stderr"

/bin/sh -n "$0"
printf 'agent launch helper contract tests passed.\n'
