#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
repo_root=$(CDPATH= cd -P "$script_dir/../.." && pwd -P)
tmp_base=$(CDPATH= cd -P "${TMPDIR:-/tmp}" && pwd -P)
test_root=
pi_binary=$(command -v pi || true)
if [ -z "$pi_binary" ]; then
    printf 'SKIP: optional Pi SDK contracts (Pi is not installed)\n'
    exit 0
fi
pi_package=$(/usr/bin/python3 - "$pi_binary" <<'PY'
import json
import pathlib
import sys

binary = pathlib.Path(sys.argv[1]).resolve()
for parent in list(binary.parents)[:3]:
    manifest = parent / "package.json"
    if manifest.is_file():
        try:
            if json.loads(manifest.read_text()).get("name") == "@earendil-works/pi-coding-agent":
                print(parent)
                break
        except (OSError, ValueError):
            pass
PY
)
if [ -z "$pi_package" ]; then
    printf 'SKIP: optional Pi SDK contracts (installed CLI does not expose an SDK package)\n'
    exit 0
fi
loader=$pi_package/node_modules/.bin/jiti
[ -x "$loader" ] || { printf 'FAIL: installed Pi TypeScript loader unavailable\n' >&2; exit 1; }
node_path=$(command -v node) || { printf 'FAIL: Node.js unavailable\n' >&2; exit 1; }
[ -f "$pi_package/dist/index.js" ] && [ -f "$pi_package/node_modules/@earendil-works/pi-ai/dist/index.js" ] \
    || { printf 'FAIL: installed Pi SDK dependencies unavailable\n' >&2; exit 1; }

cleanup() {
    status=$?
    trap - 0 HUP INT TERM
    case "${test_root:-}" in
        "$tmp_base"/quicktty-messaging-adapter-test.*)
            [ ! -L "$test_root" ] && [ -d "$test_root" ] && /bin/rm -rf "$test_root"
            ;;
        "") ;;
        *) printf 'FAIL: refusing to remove unexpected test path\n' >&2 ;;
    esac
    exit "$status"
}
trap cleanup 0 HUP INT TERM
test_root=$(/usr/bin/mktemp -d "$tmp_base/quicktty-messaging-adapter-test.XXXXXX")
umask 077
/usr/bin/python3 - "$repo_root/QuickTTY/Resources/AgentSessionIntegrations/pi/index.ts" "$test_root" <<'PY'
import json
import pathlib
import sys

source, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = source.read_text()
placeholder = '"__QUICKTTY_HELPER_PATH__"'
if text.count(placeholder) != 1:
    raise SystemExit("Pi helper placeholder is not exact")
(root / "index.ts").write_text(text.replace(placeholder, json.dumps(str(root / "helper.py"))))
PY
cat >"$test_root/helper.py" <<'PY'
#!/usr/bin/python3
import json
import os
import pathlib
import sys
import time

root = pathlib.Path(__file__).parent
if sys.argv[1:4] == ["internal", "hook", "pi"]:
    lifecycle = json.load(sys.stdin)
    raise SystemExit(1 if lifecycle.get("session_id") == "not-registered" else 0)
if sys.argv[1:] != ["agent", "request"]:
    raise SystemExit("unexpected helper grammar")
request = json.load(sys.stdin)
with (root / "calls.jsonl").open("a") as output:
    output.write(json.dumps(request, separators=(",", ":")) + "\n")
record = root / (request["requestID"] + ".json")
operation = request["operation"]
if operation in ["question", "action", "notify"]:
    temporary = root / (request["requestID"] + str(os.getpid()) + ".tmp")
    temporary.write_text(json.dumps(request))
    temporary.replace(record)
original = json.loads(record.read_text()) if record.exists() else {}
response = {"version": 1, "requestID": request["requestID"], "state": "pending"}
if operation == "notify":
    response["state"] = "accepted"
elif operation == "cancel":
    response["state"] = "cancelled"
    cancelled = root / (request["requestID"] + str(os.getpid()) + ".cancel.tmp")
    cancelled.write_text(json.dumps({"state": "cancelled"}))
    cancelled.replace(root / (request["requestID"] + ".answer.json"))
elif original.get("text", "").startswith("SDK fixture: "):
    answer = root / (request["requestID"] + ".answer.json")
    deadline = time.monotonic() + request.get("timeoutMilliseconds", 0) / 1000
    while operation == "wait" and not answer.exists() and time.monotonic() < deadline:
        time.sleep(0.025)
    if answer.exists():
        response.update(json.loads(answer.read_text()))
elif original.get("text") == "wrong-id":
    response.update(requestID="00000000-0000-0000-0000-000000000000", state="approved")
elif original.get("text") == "uncertain" and operation == "question":
    response.update(state="error", code="deliveryUncertain")
elif operation in ["wait", "status"]:
    if original.get("operation") == "action":
        response["state"] = "denied" if original["text"] == "deny" else "approved"
    elif original.get("choices"):
        response.update(state="choice", choiceIndex=1, text=original["choices"][1])
    else:
        response.update(state="text", text="A user answer")
print(json.dumps(response), flush=True)
PY
chmod 700 "$test_root/helper.py"
cat >"$test_root/contract.ts" <<'TS'
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import extension from "./index.ts";

const root = process.argv[2];
const calls = () => existsSync(join(root, "calls.jsonl"))
  ? readFileSync(join(root, "calls.jsonl"), "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line)) : [];
const tools = new Map<string, any>();
const handlers = new Map<string, any>();
const api = {
  on: (name: string, handler: any) => handlers.set(name, handler),
  registerTool: (tool: any) => tools.set(tool.name, tool),
};
const context = { sessionManager: { getSessionId: () => "private-session-do-not-render" }, cwd: "/tmp" };

async function main() {
  extension(api as unknown as ExtensionAPI);
  assert.equal(calls().length, 0, "factory started an external process");
  assert.equal(tools.size, 0, "tools were exposed before accepted lifecycle registration");
  await handlers.get("session_start")({ reason: "startup" }, context);
  assert.equal(tools.size, 3);
  for (const tool of tools.values()) {
    assert.equal(tool.exposure, "model-only");
    assert.equal(tool.executionMode, "sequential");
    assert.equal(tool.parameters.type, "object");
    assert.equal(tool.parameters.additionalProperties, false);
  }
  const ask = tools.get("quicktty_ask_user");
  const confirm = tools.get("quicktty_confirm_action");
  const notify = tools.get("quicktty_notify");
  const execute = (tool: any, id: string, params: unknown, signal?: AbortSignal) => tool.execute(id, params, signal, undefined, context);
  const question = await execute(ask, "question-1", { question: "Choose?", choices: ["One", "Two"] });
  assert.equal(question.details.state, "choice");
  assert.equal(question.details.text, "Two");
  assert(!JSON.stringify(question).includes("private-session-do-not-render"));
  const initialCount = calls().length;
  const replay = await execute(ask, "question-1", { question: "Choose?", choices: ["One", "Two"] });
  assert.deepEqual(replay, question);
  assert.equal(calls().length, initialCount, "replay sent another question");
  const conflict = await execute(ask, "question-1", { question: "Changed?" });
  assert.equal(conflict.details.code, "requestIDConflict");
  assert.equal(calls().length, initialCount);
  const approved = await execute(confirm, "action-1", { operation: "Exact action", resources: "test-only", consequences: "test-only" });
  assert.equal(approved.details.state, "approved");
  const action = calls().find((value) => value.requestID === approved.details.requestID && value.operation === "action");
  assert.equal(action.elevated, true, "action did not default to elevated");
  assert.equal(action.sessionID, "private-session-do-not-render");
  const denied = await execute(confirm, "action-2", { operation: "deny", resources: "test-only", consequences: "test-only" });
  assert.equal(denied.details.state, "denied");
  const uncertain = await execute(ask, "question-uncertain", { question: "uncertain" });
  assert.equal(uncertain.details.state, "text");
  const recoveryCalls = calls().filter((value) => value.requestID === uncertain.details.requestID);
  assert.deepEqual(recoveryCalls.map((value) => value.operation), ["question", "status"]);
  const wrong = await execute(confirm, "action-wrong", { operation: "wrong-id", resources: "test-only", consequences: "test-only" });
  assert.equal(wrong.details.state, "error");
  assert.equal(wrong.details.code, "deliveryUncertain");
  const beforeInvalid = calls().length;
  const invalid = await execute(ask, "too-large", { question: "x".repeat(2_305) });
  assert.equal(invalid.details.code, "invalidRequest");
  const abort = new AbortController();
  abort.abort();
  const aborted = await execute(confirm, "aborted", { operation: "Never run", resources: "test-only", consequences: "test-only" }, abort.signal);
  assert.equal(aborted.details.code, "cancelled");
  assert.equal(calls().length, beforeInvalid, "invalid or aborted request reached helper");
  const notice = await execute(notify, "notice-1", { status: "completed", summary: "Finished fixture" });
  assert.equal(notice.details.state, "accepted");
  const pending = execute(ask, "shutdown", { question: "Shut down while waiting" });
  await handlers.get("session_shutdown")({ reason: "reload" }, context);
  const cancelled = await pending;
  assert.equal(cancelled.details.code, "cancelled");
  assert.equal((await execute(ask, "after-stop", { question: "Must not restart" })).details.code, "cancelled");
  const outsideTools = new Map<string, any>();
  const outsideHandlers = new Map<string, any>();
  extension({ on: (event: string, handler: any) => outsideHandlers.set(event, handler), registerTool: (tool: any) => outsideTools.set(tool.name, tool) } as unknown as ExtensionAPI);
  await outsideHandlers.get("session_start")({ reason: "startup" }, { cwd: "/tmp", sessionManager: { getSessionId: () => "not-registered" } });
  assert.equal(outsideTools.size, 0, "an unregistered agent gained QuickTTY tools");
  console.log("PASS: Pi messaging adapter (installed SDK loader, mock API/helper; no agent, GUI, network, or credentials)");
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
TS
/usr/bin/python3 - "$loader" "$test_root/contract.ts" "$test_root" <<'PY'
import subprocess
import sys

subprocess.run(sys.argv[1:], check=True, timeout=30)
PY
/usr/bin/python3 - "$node_path" "$script_dir/fixtures/agent-messaging-pi-runtime-contract.mjs" "$test_root" "$pi_package" <<'PY'
import os
import pathlib
import signal
import subprocess
import sys

node, fixture, root, package = sys.argv[1:]
root = pathlib.Path(root)
for name in ["sdk-home", "sdk-agent", "sdk-workspace", "sdk-tmp", "sdk-cache", "sdk-config", "sdk-sessions"]:
    (root / name).mkdir()
environment = {
    "PATH": str(pathlib.Path(node).parent) + ":/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME": str(root / "sdk-home"),
    "TMPDIR": str(root / "sdk-tmp"),
    "XDG_CACHE_HOME": str(root / "sdk-cache"),
    "XDG_CONFIG_HOME": str(root / "sdk-config"),
    "PI_CODING_AGENT_DIR": str(root / "sdk-agent"),
    "PI_CODING_AGENT_SESSION_DIR": str(root / "sdk-sessions"),
    "PI_OFFLINE": "1", "PI_TELEMETRY": "0", "PI_SKIP_VERSION_CHECK": "1",
    "CI": "1", "TERM": "dumb",
}
process = subprocess.Popen([node, fixture, str(root), package], cwd=root / "sdk-workspace",
                           env=environment, stdin=subprocess.DEVNULL, start_new_session=True)
try:
    result = process.wait(timeout=45)
except subprocess.TimeoutExpired:
    # The unreaped leader keeps this process group owned by the fixture.
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    raise SystemExit("FAIL: isolated Pi SDK runtime timed out")
if result:
    raise SystemExit(result)
PY
"$script_dir/agent-messaging-test.sh" --pi-e2e "$node_path" "$pi_package"
