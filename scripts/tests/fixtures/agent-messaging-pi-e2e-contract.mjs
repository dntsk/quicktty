import assert from "node:assert/strict";
import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { Socket } from "node:net";
import { setTimeout as delay } from "node:timers/promises";

const [root, piPackage] = process.argv.slice(2);
assert(root && piPackage);
assert.equal(process.env.HOME, join(root, "sdk-home"));
assert.equal(process.env.PI_CODING_AGENT_DIR, join(root, "sdk-agent"));
assert.equal(process.env.PI_OFFLINE, "1");
let networkAttempts = 0;
const forbidNetwork = () => {
  networkAttempts++;
  throw new Error("Unexpected Node network in authenticated Pi contract");
};
globalThis.fetch = forbidNetwork;
Socket.prototype.connect = forbidNetwork;
// The host owns stdin; losing it must not leave a fixture agent waiting unattended.
process.stdin.on("end", () => process.exit(1));
process.stdin.resume();

const sdk = await import(pathToFileURL(join(piPackage, "dist/index.js")).href);
const ai = await import(pathToFileURL(join(piPackage, "node_modules/@earendil-works/pi-ai/dist/index.js")).href);
const runtime = await sdk.ModelRuntime.create({
  credentials: new ai.InMemoryCredentialStore(), modelsPath: null,
  refreshOnCreate: false, allowModelNetwork: false,
});
const faux = ai.fauxProvider({ provider: "quicktty-e2e-fixture", tokensPerSecond: 0 });
runtime.registerNativeProvider(faux.provider);
const settings = sdk.SettingsManager.inMemory({ compaction: { enabled: false }, retry: { enabled: false }, packages: [] });
const sessionManager = sdk.SessionManager.inMemory(process.cwd());
const loader = new sdk.DefaultResourceLoader({
  cwd: process.cwd(), agentDir: process.env.PI_CODING_AGENT_DIR, settingsManager: settings,
  noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
  additionalExtensionPaths: [join(root, "index.ts")],
});
await loader.reload();
assert.deepEqual(loader.getExtensions().errors, []);
let effects = 0;
const { session } = await sdk.createAgentSession({
  cwd: process.cwd(), agentDir: process.env.PI_CODING_AGENT_DIR,
  modelRuntime: runtime, model: faux.getModel(), thinkingLevel: "off",
  resourceLoader: loader, sessionManager, settingsManager: settings, noTools: "builtin",
  customTools: [{
    name: "fixture_effect", label: "Fixture effect", description: "Increment a test-only memory counter",
    parameters: { type: "object", properties: {}, additionalProperties: false },
    async execute() {
      effects++;
      return { content: [{ type: "text", text: "fixture-effect" }], details: {} };
    },
  }],
});
const errors = [];
const call = (name, args, id) => ai.fauxAssistantMessage(ai.fauxToolCall(name, args, { id }), { stopReason: "toolUse" });
const final = (text) => ai.fauxAssistantMessage(text);
const mark = (name) => writeFileSync(join(root, name), "fixture-stage\n");
async function wait(name) {
  const deadline = performance.now() + 10_000;
  while (!existsSync(join(root, name))) {
    assert(performance.now() < deadline, `Timed out awaiting ${name}`);
    await delay(10);
  }
}
function reply(context, name) {
  const message = [...context.messages].reverse().find((value) => value.role === "toolResult" && value.toolName === name);
  assert(message, `Missing ${name} SDK result`);
  const text = message.content.filter((value) => value.type === "text").map((value) => value.text).join("");
  assert(!text.includes(sessionManager.getSessionId()), "Tool result exposed native session ID");
  assert(!text.includes(process.env.QUICKTTY_PANE_TOKEN), "Tool result exposed pane credential");
  return JSON.parse(text);
}

try {
  await session.bindExtensions({ onError: (error) => errors.push(error) });
  assert(session.getActiveToolNames().includes("quicktty_ask_user"), "Real CLI lifecycle registration did not expose tools");
  mark("sdk-ready");
  await wait("host-granted");
  faux.setResponses([
    call("quicktty_ask_user", { question: "E2E fixture: choose", choices: ["One", "Two"] }, "e2e-question"),
    (context) => {
      const answer = reply(context, "quicktty_ask_user");
      assert.equal(answer.state, "choice");
      assert.equal(answer.choiceIndex, 1);
      assert.equal(answer.text, "Two");
      return final("question-continued");
    },
  ]);
  await session.prompt("Run authenticated question fixture");
  assert.equal(session.getLastAssistantText(), "question-continued");
  mark("sdk-question-done");
  faux.setResponses([
    call("quicktty_ask_user", { question: "E2E fixture: free text" }, "e2e-text"),
    (context) => {
      const answer = reply(context, "quicktty_ask_user");
      assert.equal(answer.state, "text");
      assert.equal(answer.text, "Explicit private fixture answer");
      return final("text-answer-continued");
    },
  ]);
  await session.prompt("Run authenticated free-text fixture");
  assert.equal(session.getLastAssistantText(), "text-answer-continued");
  mark("sdk-text-done");
  faux.setResponses([
    call("quicktty_confirm_action", { operation: "E2E fixture: approve", resources: "memory counter", consequences: "increment fixture only" }, "e2e-approve"),
    (context) => {
      assert.equal(reply(context, "quicktty_confirm_action").state, "approved");
      return call("fixture_effect", {}, "e2e-effect");
    },
    () => final("approved-effect-complete"),
  ]);
  await session.prompt("Run authenticated elevated approval fixture");
  assert.equal(session.getLastAssistantText(), "approved-effect-complete");
  assert.equal(effects, 1);
  mark("sdk-approved");
  faux.setResponses([
    call("quicktty_confirm_action", { operation: "E2E fixture: deny", resources: "memory counter", consequences: "must not increment" }, "e2e-deny"),
    (context) => {
      assert.equal(reply(context, "quicktty_confirm_action").state, "denied");
      return final("denied-without-effect");
    },
  ]);
  await session.prompt("Run authenticated denial fixture");
  assert.equal(session.getLastAssistantText(), "denied-without-effect");
  assert.equal(effects, 1);
  mark("sdk-denied");
  faux.setResponses([
    call("quicktty_notify", { status: "completed", summary: "E2E fixture: completed" }, "e2e-notify"),
    (context) => {
      assert.equal(reply(context, "quicktty_notify").state, "accepted");
      return final("notification-accepted");
    },
  ]);
  await session.prompt("Run authenticated notification fixture");
  assert.equal(session.getLastAssistantText(), "notification-accepted");
  faux.setResponses([call("quicktty_ask_user", { question: "E2E fixture: abort" }, "e2e-abort")]);
  const aborting = session.prompt("Run authenticated abort fixture");
  await wait("host-abort");
  await session.abort();
  await aborting;
  mark("sdk-aborted");
  await wait("host-cancel-checked");
  faux.setResponses([
    call("quicktty_ask_user", { question: "E2E fixture: revoke" }, "e2e-revoke"),
    (context) => {
      const answer = reply(context, "quicktty_ask_user");
      assert(answer.state === "revoked" || (answer.state === "error" && ["cancelled", "permissionRequired"].includes(answer.code)));
      assert.equal(effects, 1);
      return final("revoked-without-effect");
    },
  ]);
  await session.prompt("Run authenticated revoke fixture");
  assert.equal(session.getLastAssistantText(), "revoked-without-effect");
  assert.equal(effects, 1);
  assert.equal(networkAttempts, 0);
  assert.deepEqual(errors, []);
  assert.deepEqual(await runtime.listCredentials(), []);
  await session.extensionRunner.emit({ type: "session_shutdown", reason: "quit" });
  console.log("PASS: Pi SDK → real CLI/authenticated IPC → mock Telegram → SDK (question/text feedback/elevated button/deny/notify/abort/revoke; no GUI or real credentials)");
} finally {
  await session.abort();
  session.dispose();
  process.stdin.pause();
}
