import assert from "node:assert/strict";
import { readFileSync, renameSync, watch, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { Socket } from "node:net";

const [root, piPackage] = process.argv.slice(2);
assert(root && piPackage);
assert.equal(process.env.HOME, join(root, "sdk-home"));
assert.equal(process.env.PI_CODING_AGENT_DIR, join(root, "sdk-agent"));
assert.equal(process.env.PI_OFFLINE, "1");
assert.equal(process.env.PI_TELEMETRY, "0");
let networkAttempts = 0;
const forbidNetwork = () => {
  networkAttempts++;
  throw new Error("Unexpected network in isolated Pi SDK contract");
};
globalThis.fetch = forbidNetwork;
Socket.prototype.connect = forbidNetwork;

const sdk = await import(pathToFileURL(join(piPackage, "dist/index.js")).href);
const ai = await import(pathToFileURL(join(piPackage, "node_modules/@earendil-works/pi-ai/dist/index.js")).href);
const calls = () => readFileSync(join(root, "calls.jsonl"), "utf8")
  .split("\n").slice(0, -1).filter(Boolean).map((line) => JSON.parse(line));
const answer = (request, reply) => {
  const file = join(root, `${request.requestID}.answer.json`);
  writeFileSync(`${file}.tmp`, JSON.stringify(reply));
  renameSync(`${file}.tmp`, file);
};

function waitForCall(predicate) {
  const existing = calls().find(predicate);
  if (existing) return Promise.resolve(existing);
  return new Promise((resolve, reject) => {
    const watcher = watch(root, () => {
      const found = calls().find(predicate);
      if (found) finish(found);
    });
    const timer = setTimeout(() => {
      watcher.close();
      reject(new Error("Timed out awaiting fixture helper request"));
    }, 5_000);
    const finish = (found) => {
      clearTimeout(timer);
      watcher.close();
      resolve(found);
    };
    const found = calls().find(predicate);
    if (found) finish(found);
  });
}

function replyFrom(context, toolName) {
  const message = [...context.messages].reverse().find((value) => value.role === "toolResult" && value.toolName === toolName);
  assert(message, `Missing ${toolName} result in real model transcript`);
  const text = message.content.filter((value) => value.type === "text").map((value) => value.text).join("");
  assert(!text.includes(sessionManager.getSessionId()), "Tool result exposed native session ID");
  return { message, reply: JSON.parse(text) };
}

const runtime = await sdk.ModelRuntime.create({
  credentials: new ai.InMemoryCredentialStore(), modelsPath: null,
  refreshOnCreate: false, allowModelNetwork: false,
});
const faux = ai.fauxProvider({ provider: "quicktty-fixture", tokensPerSecond: 0 });
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
      return { content: [{ type: "text", text: "fixture-effect" }], details: { effects } };
    },
  }],
});
const errors = [];
const toolCall = (name, args, id) => ai.fauxAssistantMessage(ai.fauxToolCall(name, args, { id }), { stopReason: "toolUse" });
const finalText = (text) => ai.fauxAssistantMessage(text);

try {
  assert(!session.getActiveToolNames().includes("quicktty_ask_user"));
  writeFileSync(join(root, "reject-next-lifecycle"), "");
  await session.bindExtensions({ onError: (error) => errors.push(error) });
  assert(!session.getActiveToolNames().includes("quicktty_ask_user"), "failed startup exposed tools");

  let continued = false;
  faux.setResponses([
    (context) => {
      const declared = ai.getCurrentTools(context.messages).map((tool) => tool.name);
      for (const name of ["quicktty_ask_user", "quicktty_confirm_action", "quicktty_notify"]) {
        assert(declared.includes(name), `First provider request missed recovered ${name}`);
      }
      assert(ai.getCurrentSystemPrompt(context.messages).includes("quicktty_confirm_action"), "recovered tools lack prompt guidelines");
      return toolCall("quicktty_ask_user", { question: "SDK fixture: choose", choices: ["One", "Two"] }, "sdk-question");
    },
    (context) => {
      const { reply } = replyFrom(context, "quicktty_ask_user");
      assert.equal(reply.state, "choice");
      assert.equal(reply.text, "Two");
      continued = true;
      return finalText("continued-after-answer");
    },
  ]);
  const questionRun = session.prompt("Run isolated question fixture");
  const waiting = await waitForCall((value) => value.operation === "wait" && calls().some((original) => original.requestID === value.requestID && original.text === "SDK fixture: choose")).catch((error) => {
    console.error("SDK fixture final message:", session.messages.at(-1));
    throw error;
  });
  assert.equal(continued, false, "Agent continued before a user answer");
  answer(waiting, { state: "choice", choiceIndex: 1, text: "Two" });
  await questionRun;
  assert.equal(session.getLastAssistantText(), "continued-after-answer");
  assert.equal(continued, true);

  faux.setResponses([
    toolCall("quicktty_confirm_action", { operation: "SDK fixture: approve", resources: "memory counter", consequences: "increment fixture only" }, "sdk-approve"),
    (context) => {
      assert.equal(replyFrom(context, "quicktty_confirm_action").reply.state, "approved");
      return toolCall("fixture_effect", {}, "sdk-effect");
    },
    () => toolCall("quicktty_notify", { status: "completed", summary: "SDK fixture: completed" }, "sdk-notify"),
    (context) => {
      assert.equal(replyFrom(context, "quicktty_notify").reply.state, "accepted");
      return finalText("approved-effect-complete");
    },
  ]);
  const approvedRun = session.prompt("Run isolated approval fixture");
  const action = await waitForCall((value) => value.operation === "action" && value.text === "SDK fixture: approve");
  assert.equal(action.elevated, true);
  assert.equal(action.sessionID, sessionManager.getSessionId());
  assert.equal(effects, 0, "Protected fixture effect ran before approval");
  answer(action, { state: "approved" });
  await approvedRun;
  assert.equal(session.getLastAssistantText(), "approved-effect-complete");
  assert.equal(effects, 1);

  faux.setResponses([
    toolCall("quicktty_confirm_action", { operation: "SDK fixture: deny", resources: "memory counter", consequences: "must not increment" }, "sdk-deny"),
    (context) => {
      assert.equal(replyFrom(context, "quicktty_confirm_action").reply.state, "denied");
      return finalText("denied-without-effect");
    },
  ]);
  const deniedRun = session.prompt("Run isolated denial fixture");
  const denied = await waitForCall((value) => value.operation === "action" && value.text === "SDK fixture: deny");
  answer(denied, { state: "denied" });
  await deniedRun;
  assert.equal(session.getLastAssistantText(), "denied-without-effect");
  assert.equal(effects, 1);

  const beforeInvalid = calls().length;
  faux.setResponses([
    toolCall("quicktty_ask_user", { question: "" }, "sdk-invalid"),
    (context) => {
      const result = [...context.messages].reverse().find((value) => value.role === "toolResult");
      assert.equal(result?.isError, true, "Real SDK schema validation accepted an empty question");
      return finalText("invalid-question-rejected");
    },
  ]);
  await session.prompt("Run isolated schema fixture");
  assert.equal(session.getLastAssistantText(), "invalid-question-rejected");
  assert.equal(calls().length, beforeInvalid, "Schema-invalid tool call reached helper");

  for (const reversed of [false, true]) {
    const beforeBatch = calls().length;
    let batchResults = [];
    const confirmID = `sdk-batch-confirm-${reversed}`;
    const effectID = `sdk-batch-effect-${reversed}`;
    const batch = [
      ai.fauxToolCall("quicktty_confirm_action", { operation: "batched action", resources: "memory counter", consequences: "must not increment" }, { id: confirmID }),
      ai.fauxToolCall("fixture_effect", {}, { id: effectID }),
    ];
    faux.setResponses([
      ai.fauxAssistantMessage(reversed ? batch.reverse() : batch, { stopReason: "toolUse" }),
      (context) => {
        batchResults = context.messages.filter((value) => value.role === "toolResult" && [confirmID, effectID].includes(value.toolCallId));
        return finalText("batch-complete");
      },
    ]);
    await session.prompt("Run isolated batch safety fixture");
    assert.equal(batchResults.length, 2);
    assert(batchResults.every((value) => value.isError), "Confirmation batched with an effect was not blocked by SDK hooks");
    assert.equal(effects, 1, "A batched protected effect executed");
    assert.equal(calls().length, beforeBatch, "A forbidden batch submitted a confirmation");
  }

  faux.setResponses([toolCall("quicktty_ask_user", { question: "SDK fixture: abort" }, "sdk-abort")]);
  const abortedRun = session.prompt("Run isolated abort fixture");
  const aborting = await waitForCall((value) => value.operation === "wait" && calls().some((original) => original.requestID === value.requestID && original.text === "SDK fixture: abort"));
  await session.abort();
  await abortedRun;
  await waitForCall((value) => value.operation === "cancel" && value.requestID === aborting.requestID);
  assert.equal(effects, 1);
  assert.equal(networkAttempts, 0);
  assert.deepEqual(errors, []);
  assert.deepEqual(await runtime.listCredentials(), []);
  await session.extensionRunner.emit({ type: "session_shutdown", reason: "quit" });
  console.log("PASS: real Pi SDK agent loop (faux provider, staged extension, question/approve/deny/notify/schema/batch/abort; no GUI, real credentials or network)");
} finally {
  await session.abort();
  session.dispose();
}
