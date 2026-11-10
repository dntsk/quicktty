import assert from "node:assert/strict";
import { appendFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { Socket } from "node:net";

const [root, sdkPackage, cli] = process.argv.slice(2);
assert(root && sdkPackage && cli);
assert.equal(process.env.HOME, join(root, "home"));
assert.equal(process.env.CLAUDE_CONFIG_DIR, join(root, "config"));
const forbidNetwork = () => { throw new Error("Unexpected SDK parent network"); };
globalThis.fetch = forbidNetwork;
Socket.prototype.connect = forbidNetwork;
const { query } = await import(pathToFileURL(join(sdkPackage, "sdk.mjs")).href);
const mode = process.env.QUICKTTY_CLAUDE_FIXTURE_OUTCOME ?? "answer";
let initialized = false;
let completed = false;
let permissionCalls = 0;
const prompt = async function* () {
  yield { type: "user", session_id: "", parent_tool_use_id: null,
    message: { role: "user", content: "Ask the fixture question using AskUserQuestion." } };
};
const agent = query({
  prompt: prompt(),
  options: {
    cwd: join(root, "workspace"), env: { ...process.env },
    pathToClaudeCodeExecutable: cli,
    tools: ["AskUserQuestion"], model: "sonnet", maxTurns: 3,
    settingSources: [], settings: join(root, "host-settings.json"), persistSession: false,
    strictMcpConfig: true, mcpServers: {},
    extraArgs: { restricted: null },
    canUseTool: async () => {
      permissionCalls++;
      return { behavior: "deny", message: "Only a validated question hook may answer this fixture" };
    },
    stderr: (value) => appendFileSync(join(root, "sdk-cli-stderr.txt"), value),
  },
});
try {
  for await (const message of agent) {
    if (message.type === "system" && message.subtype === "init") {
      initialized = true;
      assert(message.tools.includes("AskUserQuestion"), "SDK did not enable native question tool");
    }
    if (message.type === "result") {
      assert.equal(message.is_error, false);
      assert.equal(message.result, "question-fixture-complete");
      completed = true;
    }
  }
  assert(initialized && completed);
  assert.equal(permissionCalls, mode === "fallback" ? 1 : 0, "Question was satisfied outside the expected hook/fallback path");
  console.log(`PASS: native Claude SDK (${mode}; no action tools or permission auto-allow)`);
} finally {
  agent.close();
}
