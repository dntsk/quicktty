import http.server
import json
import os
import pathlib
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time

base, cli, sdk, node, sdk_fixture = (pathlib.Path(value).resolve() for value in sys.argv[1:])
assert json.loads((sdk / "package.json").read_text())["version"] == "0.3.318", "Unsupported fixture SDK version"
subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(cli)], check=True, timeout=10)


def quoted(value):
    return json.dumps(str(value))


def profile(root, port=None):
    read_paths = [base, sdk, "/System/Library/Frameworks", "/System/Library/PrivateFrameworks",
                  "/System/Library/dyld", "/usr/lib", "/usr/share", "/private/var/db/timezone",
                  "/Library/Developer/CommandLineTools/usr/lib", "/opt/homebrew/Cellar", "/opt/homebrew/opt"]
    literals = [cli, node, sdk_fixture, "/Library/Developer/CommandLineTools/usr/bin/git", "/bin/sh", "/bin/bash",
                "/System/Library/CoreServices/SystemVersion.plist", "/private/etc/localtime",
                "/dev/null", "/dev/zero", "/dev/urandom", "/dev/random", "/dev/dtracehelper"]
    result = '(version 1)\n(deny default)\n(import "dyld-support.sb")\n'
    result += '(deny process-exec (literal "/usr/bin/security"))\n'
    result += '(allow syscall*)\n(allow mach-bootstrap)\n(allow process-fork)\n'
    result += '(allow process-info* (target self))\n(allow process-info-pidinfo)\n(allow sysctl-read)\n(allow file-read-metadata)\n'
    result += '(allow file-read-data file-write-data (subpath "/dev/fd"))\n'
    result += '(allow file-read* file-map-executable ' + ' '.join('(subpath ' + quoted(path) + ')' for path in read_paths)
    result += ' ' + ' '.join('(literal ' + quoted(path) + ')' for path in literals) + ')\n'
    result += '(allow file-write* (subpath ' + quoted(base) + ') (literal "/dev/null"))\n'
    result += '(allow process-exec (subpath ' + quoted(base) + ') ' + ' '.join('(literal ' + quoted(path) + ')' for path in [cli, node, "/Library/Developer/CommandLineTools/usr/bin/git", "/bin/sh", "/bin/bash"]) + ')\n'
    if port:
        result += '(allow network-outbound (remote ip "localhost:' + str(port) + '"))\n'
    return result


def environment(root, mode):
    return {
        "PATH": str(base / "bin") + ":/Library/Developer/CommandLineTools/usr/bin:/usr/bin:/bin",
        "HOME": str(root / "home"), "TMPDIR": str(root / "tmp"),
        "CLAUDE_CONFIG_DIR": str(root / "config"), "CLAUDE_CODE_TMPDIR": str(root / "tmp"),
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "OPENSSL_CONF": "/dev/null",
        "QUICKTTY_CLAUDE_MOCK_MARKER": str(root / "empty-keychain-called"),
        "QUICKTTY_CLAUDE_FIXTURE_OUTCOME": mode,
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": str(root / "gitconfig"),
        "TERM": "dumb", "CI": "1",
    }


questions = [{"question": "Which fixture option?", "header": "Fixture", "multiSelect": False,
              "options": [{"label": "One", "description": "First fixture option"},
                          {"label": "Two", "description": "Second fixture option"}]}]


def run(mode, directory=None):
    root = base / (directory or mode)
    for name in ["", "home", "tmp", "config", "workspace"]:
        (root / name).mkdir(exist_ok=True)
    os.link(base / "quicktty", root / "quicktty")
    requests = []
    results = []
    failures = []
    instruction_seen = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            if length > 4_000_000:
                self.send_error(413)
                return
            body = json.loads(self.rfile.read(length))
            requests.append(self.path)
            if "QuickTTY remote questions and one-time decisions" in json.dumps(body):
                instruction_seen.append(True)
            if self.path.endswith("count_tokens"):
                payload = b'{"input_tokens":10}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            for message in body.get("messages", []):
                content = message.get("content", [])
                if isinstance(content, list):
                    results.extend(block for block in content if block.get("type") == "tool_result" and block.get("tool_use_id") == "toolu_quicktty_fixture")
            ask = not results
            if ask:
                deadline = time.monotonic() + 10
                while not (root / "host-ready").exists():
                    if time.monotonic() >= deadline:
                        failures.append("Host did not reach the grant/fallback stage")
                        self.send_error(500)
                        return
                    time.sleep(0.01)
            block = {"type": "tool_use", "id": "toolu_quicktty_fixture", "name": "AskUserQuestion", "input": {}} if ask else {"type": "text", "text": ""}
            delta = {"type": "input_json_delta", "partial_json": json.dumps({"questions": questions})} if ask else {"type": "text_delta", "text": "question-fixture-complete"}
            message = {"id": "msg_quicktty_fixture", "type": "message", "role": "assistant", "content": [], "model": body.get("model"), "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 0}}
            events = [("message_start", {"type": "message_start", "message": message}),
                      ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": block}),
                      ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": delta}),
                      ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                      ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "tool_use" if ask else "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 10}}),
                      ("message_stop", {"type": "message_stop"})]
            payload = "".join("event: " + event + "\ndata: " + json.dumps(data) + "\n\n" for event, data in events).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = environment(root, mode)
    env["ANTHROPIC_API_KEY"] = "sk-ant-quicktty-synthetic-fixture-only"
    env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:" + str(server.server_port)
    sandbox = root / "runtime.sb"
    sandbox.write_text(profile(root, server.server_port))
    try:
        if mode == "answer":
            version = subprocess.run(["/usr/bin/sandbox-exec", "-f", str(sandbox), str(cli), "--version"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=10)
            assert version.stdout.decode().strip() == "2.1.318 (Claude Code)", "Unsupported native CLI version"
        with tempfile.NamedTemporaryFile(prefix="quicktty-native-outside-synthetic-", dir="/tmp") as outside:
            outside.write(b"synthetic data, not a credential"); outside.flush()
            subprocess.run(["/usr/bin/sandbox-exec", "-f", str(sandbox), str(base / "privacy-probe"), str(sandbox), outside.name, str(server.server_port)], env=env, check=True, timeout=5)
        command = [str(base / "native-host"), str(root), str(node), str(sdk), str(cli), str(sdk_fixture)]
        process = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=35)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
        if stderr:
            sys.stderr.buffer.write(stderr)
        sys.stdout.buffer.write(stdout)
        sys.stdout.flush()
        assert process.returncode == 0, "Native host fixture failed in " + mode
        assert not failures, failures
        assert results, "Native CLI did not continue to a tool result"
        assert instruction_seen, "Accepted SessionStart did not inject the shared CLI instructions"
        if mode == "answer":
            assert any("Two" in json.dumps(value) and not value.get("is_error", False) for value in results), "Native tool did not accept the answer"
        else:
            assert all(value.get("is_error") and "Two" not in json.dumps(value) for value in results), "Closed/unavailable question fabricated an answer"
        assert (root / "empty-keychain-called").exists(), "Native CLI did not use the empty Keychain fixture"
        print("PASS: pinned Claude CLI 2.1.318 / SDK 0.3.318 native contract:", mode, flush=True)
    finally:
        server.shutdown()
        server.server_close()


for outcome in ["answer", "cancel", "revoke", "fallback"]:
    run(outcome)

renamed = base / "2.1.318"
shutil.copyfile(cli, renamed)
renamed.chmod(0o700)
cli = renamed
run("answer", "renamed-answer")
print("PASS: renamed exact native artifact uses its bytes, not the executable filename", flush=True)
