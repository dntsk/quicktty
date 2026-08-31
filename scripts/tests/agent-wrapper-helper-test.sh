#!/bin/sh
set -eu

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
repo_root=$(CDPATH= cd -P "$script_dir/../.." && pwd -P)
TMPDIR=${TMPDIR:-/tmp}
tmp_base=$(CDPATH= cd -P "$TMPDIR" && pwd -P)
test_root=
cleanup() {
    status=$?
    trap - 0 HUP INT TERM
    case ${test_root:-} in
        "$tmp_base"/quicktty-agent-wrapper-test.*) [ ! -L "$test_root" ] && /bin/rm -rf "$test_root" ;;
        "") ;;
        *) printf 'FAIL: refusing cleanup: %s\n' "$test_root" >&2 ;;
    esac
    exit "$status"
}
trap cleanup 0 HUP INT TERM
test_root=$(/usr/bin/mktemp -d "$tmp_base/quicktty-agent-wrapper-test.XXXXXX")
helper=$test_root/quicktty
wrapper_dir=$test_root/wrappers
real_dir=$test_root/real
work_dir=$test_root/work
/bin/mkdir -p "$wrapper_dir" "$real_dir" "$work_dir"

cat >"$test_root/ipc_server.py" <<'PY'
import hashlib, hmac, json, struct

PREFLIGHT_SIZE = 76
PROOF_DOMAIN = b"QuickTTY.AgentIPC.ServerProof.v1\0"


def recv_exact(connection, size):
    payload = b""
    while len(payload) < size:
        chunk = connection.recv(size - len(payload))
        if not chunk:
            raise AssertionError("truncated IPC payload")
        payload += chunk
    return payload


def recv_message(connection, token):
    preflight = recv_exact(connection, PREFLIGHT_SIZE)
    assert preflight[:8] == b"QTTYIPC\0"
    assert struct.unpack(">I", preflight[8:12])[0] == 1
    proof_input = PROOF_DOMAIN + preflight[44:76] + preflight[8:44]
    proof = hmac.new(bytes.fromhex(token), proof_input, hashlib.sha256).digest()
    connection.sendall(b"\x01" + proof)
    size = struct.unpack(">I", recv_exact(connection, 4))[0]
    message = json.loads(recv_exact(connection, size))
    return message.get("payload", message)
PY
PYTHONPATH="$test_root${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONPATH

/usr/bin/xcrun --sdk macosx swiftc -D QUICKTTY_TESTING \
    "$repo_root"/Shared/AgentIntegrations/*.swift \
    "$repo_root"/Shared/AgentIntegrations/Installer/*.swift \
    "$repo_root"/QuickTTYCLI/*.swift \
    -o "$helper"
/bin/cp "$repo_root/QuickTTY/Resources/AgentSessionIntegrations/amp/wrapper/amp" "$wrapper_dir/amp"
/bin/chmod 755 "$wrapper_dir/amp"

cat >"$real_dir/amp" <<'PY'
#!/usr/bin/python3
import base64, json, os, struct, sys
record = {
    "argv": [[len(value.encode()), base64.b64encode(value.encode()).decode()] for value in sys.argv],
    "cwd": os.getcwd(),
    "env": {key: os.environ.get(key) for key in [
        "QUICKTTY_PANE_ID", "QUICKTTY_AGENT_SOCKET", "QUICKTTY_INSTANCE_ID",
        "QUICKTTY_PANE_TOKEN", "QUICKTTY_AGENT_HELPER", "QUICKTTY_WRAPPER_DIR",
        "QUICKTTY_WRAPPER_PATH", "QUICKTTY_WRAPPER_PAYLOAD"]},
    "stdin": base64.b64encode(sys.stdin.buffer.read()).decode(),
}
open(os.environ["RECORD"], "w").write(json.dumps(record, sort_keys=True))
sys.stdout.write("stdout-ok\n")
sys.stderr.write("stderr-ok\n")
sys.exit(int(os.environ.get("EXIT_CODE", "0")))
PY
/bin/chmod 755 "$real_dir/amp"
printf 'stdin-data\n' >"$test_root/stdin"
(
    cd "$work_dir"
    PATH="$wrapper_dir:$real_dir:/usr/bin:/bin" \
    QUICKTTY_AGENT_HELPER="$helper" QUICKTTY_PANE_ID=pane QUICKTTY_INSTANCE_ID=instance \
    QUICKTTY_PANE_TOKEN=token QUICKTTY_AGENT_SOCKET="$test_root/missing.sock" \
    RECORD="$test_root/record" EXIT_CODE=37 \
    "$wrapper_dir/amp" '' '猫' 'line one
line two' <"$test_root/stdin" >"$test_root/stdout" 2>"$test_root/stderr" || status=$?
    [ "${status:-0}" = 37 ] || exit 91
)
[ "$(/bin/cat "$test_root/stdout")" = stdout-ok ] || fail 'stdout was not inherited'
[ "$(/bin/cat "$test_root/stderr")" = stderr-ok ] || fail 'stderr was not inherited'
/usr/bin/python3 - "$test_root/record" "$real_dir/amp" "$work_dir" <<'PY'
import base64, json, sys
record = json.load(open(sys.argv[1]))
expected = [sys.argv[2], "", "猫", "line one\nline two"]
actual = [base64.b64decode(value).decode() for _, value in record["argv"]]
assert actual == expected, (actual, expected)
assert [size for size, _ in record["argv"]] == [len(x.encode()) for x in expected]
assert record["cwd"] == sys.argv[3]
assert base64.b64decode(record["stdin"]) == b"stdin-data\n"
assert record["env"]["QUICKTTY_PANE_ID"] == "pane"
for key in ["QUICKTTY_WRAPPER_DIR", "QUICKTTY_WRAPPER_PATH", "QUICKTTY_WRAPPER_PAYLOAD"]:
    assert record["env"][key] is None
PY

cat >"$real_dir/opencode" <<'PY'
#!/usr/bin/python3
import os, signal
os.write(1, b"R")
signal.pause()
PY
/bin/chmod 755 "$real_dir/opencode"
/usr/bin/python3 - "$helper" "$real_dir" <<'PY'
import os, signal, subprocess, sys
helper, real_dir = sys.argv[1:]
environment = os.environ.copy()
environment.update({"PATH": real_dir + ":/usr/bin:/bin"})
process = subprocess.Popen(
    [helper, "internal", "wrap", "opencode", "--", "undocumented"],
    env=environment, stdout=subprocess.PIPE)
assert process.stdout.read(1) == b"R"
os.kill(process.pid, signal.SIGTERM)
assert process.wait() == 143, process.returncode
PY

cat >"$real_dir/opencode" <<'PY'
#!/usr/bin/python3
import os
try:
    os.fstat(int(os.environ["UNRELATED_FD"]))
except OSError:
    os.write(1, b"closed")
else:
    os.write(1, b"inherited")
PY
/bin/chmod 755 "$real_dir/opencode"
/usr/bin/python3 - "$helper" "$real_dir" <<'PY'
import os, subprocess, sys
helper, real_dir = sys.argv[1:]
read_fd, write_fd = os.pipe()
environment = os.environ.copy()
environment.update({
    "PATH": real_dir + ":/usr/bin:/bin",
    "UNRELATED_FD": str(write_fd),
})
process = subprocess.Popen([
    helper, "internal", "wrap", "opencode", "--", "--session", "fd-test"
], env=environment, pass_fds=(write_fd,), stdout=subprocess.PIPE)
os.close(write_fd)
os.close(read_fd)
assert process.communicate()[0] == b"closed"
assert process.returncode == 0
PY

cat >"$real_dir/opencode" <<'PY'
#!/usr/bin/python3
import os, signal

def grandchild_term(signum, frame):
    os.write(1, b"G")
    os._exit(128 + signum)

def grandchild_winch(signum, frame):
    os.write(1, b"w")

child = os.fork()
if child == 0:
    signal.signal(signal.SIGTERM, grandchild_term)
    signal.signal(signal.SIGWINCH, grandchild_winch)
    os.write(1, b"g")
    while True:
        signal.pause()

def parent_term(signum, frame):
    os.write(1, b"P")
    os.waitpid(child, 0)
    os._exit(128 + signum)

def parent_winch(signum, frame):
    os.write(1, b"W")

signal.signal(signal.SIGTERM, parent_term)
signal.signal(signal.SIGWINCH, parent_winch)
os.write(1, b"p")
while True:
    signal.pause()
PY
/bin/chmod 755 "$real_dir/opencode"
/usr/bin/python3 - "$helper" "$real_dir" <<'PY'
import os, signal, subprocess, sys
helper, real_dir = sys.argv[1:]
environment = os.environ.copy()
environment["PATH"] = real_dir + ":/usr/bin:/bin"
process = subprocess.Popen(
    [helper, "internal", "wrap", "opencode", "--", "group-test"],
    env=environment, stdout=subprocess.PIPE)
assert set(process.stdout.read(2)) == set(b"pg")
os.kill(process.pid, signal.SIGWINCH)
assert set(process.stdout.read(2)) == set(b"Ww")
os.kill(process.pid, signal.SIGTERM)
assert set(process.stdout.read(2)) == set(b"PG")
assert process.wait() == 143, process.returncode
PY

cat >"$real_dir/opencode" <<'PY'
#!/usr/bin/python3
import os, signal, sys, termios
assert os.tcgetpgrp(0) == os.getpgrp()
attributes = termios.tcgetattr(0)
original_local_flags = attributes[3]
attributes[3] &= ~(termios.ECHO | termios.ICANON)
attributes[6][termios.VMIN] = 1
attributes[6][termios.VTIME] = 0
termios.tcsetattr(0, termios.TCSANOW, attributes)
os.write(1, ("READY {} {} {}\n".format(
    os.getpgrp(), os.tcgetpgrp(0), original_local_flags
)).encode())
assert os.read(0, 1) == b"x"
os.write(1, b"READ-OK\n")
os.killpg(os.getpgrp(), signal.SIGSTOP)
assert os.read(0, 1) == b"y"
assert os.tcgetpgrp(0) == os.getpgrp()
os.write(1, b"FG-READ\n")
sys.exit(29)
PY
/bin/chmod 755 "$real_dir/opencode"
/usr/bin/python3 - "$helper" "$real_dir" <<'PY'
import os, pty, select, signal, socket, sys, termios
from ipc_server import recv_message
helper, real_dir = sys.argv[1:]
socket_path = "/tmp/qtty-wrapper-{}-pty.sock".format(os.getpid())
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(socket_path)
server.listen(2)
environment = os.environ.copy()
environment.update({
    "PATH": real_dir + ":/usr/bin:/bin",
    "QUICKTTY_AGENT_SOCKET": socket_path,
    "QUICKTTY_INSTANCE_ID": "11111111-1111-1111-1111-111111111111",
    "QUICKTTY_PANE_ID": "22222222-2222-2222-2222-222222222222",
    "QUICKTTY_PANE_TOKEN": "ab" * 32,
})
gate_read, gate_write = os.pipe()
status_read, status_write = os.pipe()
command_read, command_write = os.pipe()
shell_pid, master = pty.fork()
if shell_pid == 0:
    os.close(gate_write)
    os.close(status_read)
    os.close(command_write)
    wrapper_pid = os.fork()
    if wrapper_pid == 0:
        os.close(status_write)
        os.close(command_read)
        os.setpgid(0, 0)
        assert os.read(gate_read, 1) == b"x"
        os.close(gate_read)
        os.execve(helper, [
            helper, "internal", "wrap", "opencode", "--", "--session", "pty-job"
        ], environment)
    os.close(gate_read)
    os.setpgid(wrapper_pid, wrapper_pid)
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTTOU})
    os.tcsetpgrp(0, wrapper_pid)
    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    status_stream = os.fdopen(status_write, "w", buffering=1)
    status_stream.write("PIDS {} {}\n".format(os.getpgrp(), wrapper_pid))
    while True:
        waited_pid, status = os.waitpid(wrapper_pid, os.WUNTRACED)
        assert waited_pid == wrapper_pid
        if os.WIFSTOPPED(status):
            status_stream.write("STOP {}\n".format(os.WSTOPSIG(status)))
            command = os.read(command_read, 1)
            assert command in (b"b", b"f")
            previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTTOU})
            os.tcsetpgrp(0, os.getpgrp() if command == b"b" else wrapper_pid)
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
            os.killpg(wrapper_pid, signal.SIGCONT)
            continue
        if os.WIFEXITED(status):
            status_stream.write("EXIT {}\n".format(os.WEXITSTATUS(status)))
        else:
            status_stream.write("SIGNAL {}\n".format(os.WTERMSIG(status)))
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTTOU})
        os.tcsetpgrp(0, os.getpgrp())
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        os._exit(0)
os.close(gate_read)
os.close(status_write)
os.close(command_read)
status_stream = os.fdopen(status_read, "r")
pids = status_stream.readline().split()
assert pids[0] == "PIDS", pids
reported_shell, wrapper_pid = map(int, pids[1:])
assert reported_shell == shell_pid
original_attributes = termios.tcgetattr(master)
os.write(gate_write, b"x")
os.close(gate_write)

output = bytearray()
def comparable_attributes(attributes):
    result = list(attributes)
    result[3] &= ~getattr(termios, "PENDIN", 0x20000000)
    return result

def read_until(marker):
    while marker not in output:
        readable, _, _ = select.select([master], [], [], 3)
        assert readable, (marker, bytes(output))
        output.extend(os.read(master, 4096))

def read_stop():
    fields = status_stream.readline().split()
    assert len(fields) == 2 and fields[0] == "STOP", (fields, bytes(output))
    return int(fields[1])

connection, _ = server.accept()
assert recv_message(connection, environment["QUICKTTY_PANE_TOKEN"])["event"] == "register"
assert termios.tcgetattr(master) == original_attributes
assert os.tcgetpgrp(master) == wrapper_pid
connection.sendall(b"\x01")
connection.close()

read_until(b"READY ")
ready_line = bytes(output).split(b"READY ", 1)[1].splitlines()[0]
child_group, child_foreground, original_local_flags = map(int, ready_line.split())
expected_attributes = list(original_attributes)
expected_attributes[3] = original_local_flags
assert child_group == child_foreground
assert child_group != wrapper_pid
assert os.tcgetpgrp(master) == child_group
os.write(master, b"x")
read_until(b"READ-OK\r\n")

assert read_stop() == signal.SIGSTOP
assert os.tcgetpgrp(master) == wrapper_pid
restored_attributes = termios.tcgetattr(master)
assert comparable_attributes(restored_attributes) == comparable_attributes(expected_attributes), (
    expected_attributes, restored_attributes
)

os.write(command_write, b"b")
assert read_stop() == signal.SIGTTIN
assert os.tcgetpgrp(master) == shell_pid
assert b"FG-READ\r\n" not in output

os.write(command_write, b"f")
os.write(master, b"y")
read_until(b"FG-READ\r\n")

connection, _ = server.accept()
assert recv_message(connection, environment["QUICKTTY_PANE_TOKEN"])["event"] == "unregister"
assert os.tcgetpgrp(master) == wrapper_pid
assert comparable_attributes(termios.tcgetattr(master)) == comparable_attributes(
    expected_attributes
)
connection.sendall(b"\x01")
connection.close()
assert status_stream.readline().split() == ["EXIT", "29"]
os.close(command_write)
_, status = os.waitpid(shell_pid, 0)
assert os.WIFEXITED(status)
assert os.WEXITSTATUS(status) == 0
os.close(master)
server.close()
os.unlink(socket_path)
PY

cat >"$real_dir/opencode" <<'PY'
#!/usr/bin/python3
import sys
sys.exit(23)
PY
/bin/chmod 755 "$real_dir/opencode"
/usr/bin/python3 - "$helper" "$real_dir" "$test_root" <<'PY'
import json, os, socket, struct, subprocess, sys
helper, real_dir, root = sys.argv[1:]
identity = {
    "QUICKTTY_INSTANCE_ID": "11111111-1111-1111-1111-111111111111",
    "QUICKTTY_PANE_ID": "22222222-2222-2222-2222-222222222222",
    "QUICKTTY_PANE_TOKEN": "ab" * 32,
}

def run(ack, suffix):
    socket_path = "/tmp/qtty-wrapper-{}-{}.sock".format(os.getpid(), suffix)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(socket_path)
    server.listen(2)
    environment = os.environ.copy()
    environment.update(identity)
    environment.update({"PATH": real_dir + ":/usr/bin:/bin", "QUICKTTY_AGENT_SOCKET": socket_path})
    process = subprocess.Popen([
        helper, "internal", "wrap", "opencode", "--", "--session", "explicit-session"]
    , env=environment)
    events = []
    for _ in range(2 if ack else 1):
        connection, _ = server.accept()
        from ipc_server import recv_message
        events.append(recv_message(connection, identity["QUICKTTY_PANE_TOKEN"])["event"])
        connection.sendall(bytes([ack]))
        connection.close()
    server.close()
    os.unlink(socket_path)
    assert process.wait() == 23
    expected = ["register", "unregister"] if ack else ["register"]
    assert events == expected, events

run(1, "accepted")
run(0, "frozen")
PY

cat >"$real_dir/opencode" <<'PY'
#!/usr/bin/python3
import os, signal
open(os.environ["SPAWN_MARKER"], "w").write("spawned")
signal.pause()
PY
/bin/chmod 755 "$real_dir/opencode"
/usr/bin/python3 - "$helper" "$real_dir" "$test_root/pre-register-spawned" <<'PY'
import os, signal, socket, subprocess, sys
from ipc_server import recv_message
helper, real_dir, spawn_marker = sys.argv[1:]
socket_path = "/tmp/qtty-wrapper-{}-setup.sock".format(os.getpid())
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(socket_path)
server.listen(1)
environment = os.environ.copy()
environment.update({
    "PATH": real_dir + ":/usr/bin:/bin",
    "QUICKTTY_AGENT_SOCKET": socket_path,
    "QUICKTTY_INSTANCE_ID": "11111111-1111-1111-1111-111111111111",
    "QUICKTTY_PANE_ID": "22222222-2222-2222-2222-222222222222",
    "QUICKTTY_PANE_TOKEN": "ab" * 32,
    "SPAWN_MARKER": spawn_marker,
})
process = subprocess.Popen([
    helper, "internal", "wrap", "opencode", "--", "--session", "setup-signal"
], env=environment)
connection, _ = server.accept()
message = recv_message(connection, environment["QUICKTTY_PANE_TOKEN"])
assert message["event"] == "register", message
os.kill(process.pid, signal.SIGTERM)
try:
    status = process.wait(timeout=1)
except subprocess.TimeoutExpired:
    process.kill()
    process.wait()
    raise AssertionError("pre-register signal did not abort promptly")
assert status == 143, status
assert connection.recv(1) == b""
assert not os.path.exists(spawn_marker)
connection.close()
server.close()
os.unlink(socket_path)
PY

cat >"$real_dir/opencode" <<'PY'
#!/usr/bin/python3
import signal
signal.pause()
PY
/bin/chmod 755 "$real_dir/opencode"
/usr/bin/python3 - "$helper" "$real_dir" <<'PY'
import json, os, socket, struct, subprocess, sys
helper, real_dir = sys.argv[1:]
socket_path = "/tmp/qtty-wrapper-{}-spawn.sock".format(os.getpid())
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(socket_path)
server.listen(2)
environment = os.environ.copy()
environment.update({
    "PATH": real_dir + ":/usr/bin:/bin",
    "QUICKTTY_AGENT_SOCKET": socket_path,
    "QUICKTTY_INSTANCE_ID": "11111111-1111-1111-1111-111111111111",
    "QUICKTTY_PANE_ID": "22222222-2222-2222-2222-222222222222",
    "QUICKTTY_PANE_TOKEN": "ab" * 32,
})
process = subprocess.Popen([
    helper, "internal", "wrap", "opencode", "--", "--session", "spawn-failure"
], env=environment)
events = []
for index in range(2):
    connection, _ = server.accept()
    from ipc_server import recv_message
    events.append(recv_message(connection, environment["QUICKTTY_PANE_TOKEN"])["event"])
    if index == 0:
        os.unlink(os.path.join(real_dir, "opencode"))
    connection.sendall(b"\x01")
    connection.close()
assert process.wait() == 1, process.returncode
assert events == ["register", "unregister"], events
server.close()
os.unlink(socket_path)
PY

cat >"$real_dir/opencode" <<'PY'
#!/usr/bin/python3
import signal
signal.pause()
PY
/bin/chmod 755 "$real_dir/opencode"
/usr/bin/python3 - "$helper" "$real_dir" <<'PY'
import errno, os, struct, subprocess, sys
helper, real_dir = sys.argv[1:]
ready_read, ready_write = os.pipe()
release_read, release_write = os.pipe()
environment = os.environ.copy()
environment.update({
    "PATH": real_dir + ":/usr/bin:/bin",
    "QUICKTTY_TEST_POSTSPAWN_READY_FD": str(ready_write),
    "QUICKTTY_TEST_POSTSPAWN_RELEASE_FD": str(release_read),
})
process = subprocess.Popen([
    helper, "internal", "wrap", "opencode", "--", "postspawn-failure"
], env=environment, pass_fds=(ready_write, release_read))
os.close(ready_write)
os.close(release_read)
child = struct.unpack("i", os.read(ready_read, 4))[0]
os.close(ready_read)
os.write(release_write, b"x")
os.close(release_write)
assert process.wait() == 1, process.returncode
try:
    os.kill(child, 0)
except OSError as error:
    assert error.errno == errno.ESRCH, error
else:
    raise AssertionError("post-spawn failure leaked child {}".format(child))
PY

cat >"$real_dir/amp" <<'PY'
#!/usr/bin/python3
import json, os, struct, sys
payload = json.dumps({
    "adapterID": "amp", "cwd": os.getcwd(), "sessionID": "plugin-thread"
}, separators=(",", ":"), sort_keys=True).encode()
os.write(int(os.environ["QUICKTTY_WRAPPER_IDENTITY_FD"]), struct.pack(">I", len(payload)) + payload)
sys.exit(19)
PY
/bin/chmod 755 "$real_dir/amp"
/usr/bin/python3 - "$helper" "$real_dir" "$test_root" <<'PY'
import json, os, socket, struct, subprocess, sys
helper, real_dir, root = sys.argv[1:]
def run(ack, suffix):
    socket_path = "/tmp/qtty-wrapper-{}-plugin-{}.sock".format(os.getpid(), suffix)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(socket_path)
    server.listen(2)
    environment = os.environ.copy()
    environment.update({
        "PATH": real_dir + ":/usr/bin:/bin",
        "QUICKTTY_AGENT_SOCKET": socket_path,
        "QUICKTTY_INSTANCE_ID": "11111111-1111-1111-1111-111111111111",
        "QUICKTTY_PANE_ID": "22222222-2222-2222-2222-222222222222",
        "QUICKTTY_PANE_TOKEN": "ab" * 32,
    })
    process = subprocess.Popen([helper, "internal", "wrap", "amp", "--"], env=environment)
    events = []
    for _ in range(2 if ack else 1):
        connection, _ = server.accept()
        from ipc_server import recv_message
        message = recv_message(connection, environment["QUICKTTY_PANE_TOKEN"])
        events.append((message["event"], message["sessionID"]))
        connection.sendall(bytes([ack]))
        connection.close()
    server.close()
    os.unlink(socket_path)
    assert process.wait() == 19
    expected = [("register", "plugin-thread"), ("unregister", "plugin-thread")]
    if not ack:
        expected.pop()
    assert events == expected, events

run(1, "accepted")
run(0, "rejected")
PY

case "$(LC_ALL=C /usr/bin/grep -Ec '(^|[^[:alnum:]_])(ps|pgrep|lsof|proc_pidinfo)([^[:alnum:]_]|$)' "$repo_root/QuickTTYCLI/InternalWrapCommand.swift")" in
    0) ;;
    *) fail 'wrapper inspects unrelated processes' ;;
esac

set +e
"$helper" internal wrap codex -- >"$test_root/unknown.out" 2>"$test_root/unknown.err"
unknown_status=$?
"$helper" internal wrap amp --injected >"$test_root/injected.out" 2>"$test_root/injected.err"
injected_status=$?
set -e
[ "$unknown_status" = 2 ] || fail 'unknown adapter was not rejected'
[ "$injected_status" = 2 ] || fail 'option injection was not rejected'
[ ! -s "$test_root/unknown.out" ] && [ ! -s "$test_root/injected.out" ] || fail 'invalid grammar wrote stdout'

/bin/sh -n "$0"
printf 'agent wrapper helper contract tests passed.\n'
