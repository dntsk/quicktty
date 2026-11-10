import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const HELPER_PATH = "__QUICKTTY_HELPER_PATH__";
const MAXIMUM_PAYLOAD_BYTES = 65_536;
const HELPER_TIMEOUT_MS = 2_000;
const STATE_KEY = "__quickttySessionIntegrationState";

type IntegrationState = {
  currentSessionID?: string;
  previousSessionID?: string;
};

type GlobalIntegrationState = typeof globalThis & {
  [STATE_KEY]?: IntegrationState;
};

function state(): IntegrationState {
  const shared = globalThis as GlobalIntegrationState;
  shared[STATE_KEY] ??= {};
  return shared[STATE_KEY];
}

function isBounded(value: string, maximumBytes: number): boolean {
  return value.length > 0 && Buffer.byteLength(value, "utf8") <= maximumBytes;
}

async function send(event: string, payload: Record<string, string>): Promise<boolean> {
  const input = Buffer.from(JSON.stringify(payload), "utf8");
  if (input.byteLength > MAXIMUM_PAYLOAD_BYTES) return false;

  return new Promise<boolean>((resolve) => {
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const finish = (accepted = false): void => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolve(accepted);
    };
    const child = spawn(HELPER_PATH, ["internal", "hook", "pi", event], {
      shell: false,
      stdio: ["pipe", "ignore", "ignore"],
    });
    timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish();
    }, HELPER_TIMEOUT_MS);
    child.once("error", () => finish());
    child.once("close", (code) => finish(code === 0));
    child.stdin.once("error", () => finish());
    child.stdin.end(input);
  });
}

type MessagingReply = {
  version: 1;
  requestID?: string;
  state: string;
  text?: string;
  choiceIndex?: number;
  code?: string;
};

type MessagingRequest = Record<string, unknown> & {
  version: 1;
  operation: string;
  requestID: string;
  sessionID: string;
};

const ERROR_CODES = new Set([
  "invalidRequest", "unavailable", "permissionRequired", "requestIDConflict",
  "requestUnavailable", "capacityExceeded", "deliveryUncertain", "timedOut", "cancelled",
]);

function failure(requestID: string, code: string): MessagingReply {
  return { version: 1, requestID, state: "error", code };
}

function parseReply(data: Buffer, request: MessagingRequest): MessagingReply {
  try {
    const reply = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(data)) as MessagingReply;
    if (reply === null || typeof reply !== "object" || Array.isArray(reply) || reply.version !== 1 || typeof reply.state !== "string") throw new Error();
    if (Object.keys(reply).some((key) => !["version", "requestID", "state", "text", "choiceIndex", "code"].includes(key))) throw new Error();
    if (reply.state === "error") {
      return failure(request.requestID, ERROR_CODES.has(reply.code ?? "") ? reply.code! : "deliveryUncertain");
    }
    if (typeof reply.requestID !== "string" || reply.requestID.toLowerCase() !== request.requestID.toLowerCase()) throw new Error();
    if (!["pending", "text", "choice", "approved", "denied", "cancelled", "expired", "revoked", "accepted"].includes(reply.state)) throw new Error();
    if (reply.text !== undefined && (typeof reply.text !== "string" || !isBounded(reply.text, 4_096))) throw new Error();
    if (reply.state === "text" && reply.text === undefined) throw new Error();
    if (reply.state === "choice" && (reply.text === undefined || !isBounded(reply.text, 64) || !Number.isInteger(reply.choiceIndex) || reply.choiceIndex! < 0 || reply.choiceIndex! >= 8)) throw new Error();
    if (!["text", "choice"].includes(reply.state) && (reply.text !== undefined || reply.choiceIndex !== undefined)) throw new Error();
    if (reply.state === "text" && reply.choiceIndex !== undefined) throw new Error();
    return { version: 1, requestID: request.requestID, state: reply.state, ...(reply.text !== undefined ? { text: reply.text } : {}), ...(reply.choiceIndex !== undefined ? { choiceIndex: reply.choiceIndex } : {}) };
  } catch {
    return failure(request.requestID, "deliveryUncertain");
  }
}

async function message(request: MessagingRequest, signal?: AbortSignal, timeout = 40_000): Promise<MessagingReply> {
  const input = Buffer.from(JSON.stringify(request), "utf8");
  if (input.length > MAXIMUM_PAYLOAD_BYTES) return failure(request.requestID, "invalidRequest");
  if (signal?.aborted) return failure(request.requestID, "cancelled");
  return new Promise((resolve) => {
    let settled = false;
    let size = 0;
    const chunks: Buffer[] = [];
    const child = spawn(HELPER_PATH, ["agent", "request"], { shell: false, stdio: ["pipe", "pipe", "ignore"] });
    const finish = (reply: MessagingReply): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      resolve(reply);
    };
    const abort = (): void => { child.kill("SIGTERM"); finish(failure(request.requestID, "cancelled")); };
    const timer = setTimeout(() => { child.kill("SIGKILL"); finish(failure(request.requestID, "deliveryUncertain")); }, timeout);
    signal?.addEventListener("abort", abort, { once: true });
    child.once("error", () => finish(failure(request.requestID, "deliveryUncertain")));
    child.stdin.once("error", () => finish(failure(request.requestID, "deliveryUncertain")));
    child.stdout.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAXIMUM_PAYLOAD_BYTES + 1) {
        child.kill("SIGKILL");
        finish(failure(request.requestID, "deliveryUncertain"));
      } else { chunks.push(chunk); }
    });
    child.once("close", () => finish(parseReply(Buffer.concat(chunks), request)));
    child.stdin.end(input);
    if (signal?.aborted) abort();
  });
}

function installMessagingTools(pi: ExtensionAPI): {
  shutdown(): Promise<void>;
  observeBatch(names: readonly string[]): void;
  guardCall(): { block: true; reason: string } | undefined;
} {
  const pending = new Map<string, MessagingRequest>();
  const cache = new Map<string, { payload: string; request: MessagingRequest; reply?: MessagingReply }>();
  let active = false;
  let stopped = false;
  let blockedBatch = false;
  const observeBatch = (names: readonly string[]): void => {
    // Blocking only confirmation would still let a sibling tool execute before approval.
    blockedBatch = typeof pi.registerTool === "function" && names.length > 1 && names.includes("quicktty_confirm_action");
  };
  const guardCall = (): { block: true; reason: string } | undefined => blockedBatch ? {
    block: true,
    reason: "QuickTTY confirmation must be called alone. This entire batch is blocked. Wait for approval before requesting the unchanged action in a later turn.",
  } : undefined;
  const cancel = async (request: MessagingRequest): Promise<void> => {
    await message({ version: 1, operation: "cancel", requestID: request.requestID, sessionID: request.sessionID }, undefined, HELPER_TIMEOUT_MS);
  };
  const shutdown = async (): Promise<void> => {
    stopped = true;
    await Promise.all([...pending.values()].map(cancel));
    pending.clear();
  };
  if (typeof pi.registerTool !== "function") return { shutdown, observeBatch, guardCall };

  // Plain JSON Schema avoids runtime package dependencies in the owned extension file.
  const schemas = {
    question: {
      type: "object", additionalProperties: false, required: ["question"],
      properties: {
        question: { type: "string", minLength: 1, maxLength: 2_304, description: "Minimal non-secret question to ask the user" },
        choices: { type: "array", maxItems: 8, uniqueItems: true, items: { type: "string", minLength: 1, maxLength: 64 } },
        timeoutSeconds: { type: "integer", minimum: 1, maximum: 1_800 },
      },
    },
    action: {
      type: "object", additionalProperties: false, required: ["operation", "resources", "consequences"],
      properties: {
        operation: { type: "string", minLength: 1, maxLength: 1_024, description: "Exact action; no secrets or omitted relevant steps" },
        resources: { type: "string", minLength: 1, maxLength: 768 },
        consequences: { type: "string", minLength: 1, maxLength: 768 },
        elevated: { type: "boolean", default: true },
        timeoutSeconds: { type: "integer", minimum: 1, maximum: 1_800 },
      },
    },
    notify: {
      type: "object", additionalProperties: false, required: ["status", "summary"],
      properties: {
        status: { type: "string", enum: ["working", "waiting", "completed", "failed"] },
        summary: { type: "string", minLength: 1, maxLength: 512, description: "Brief non-secret status, not a transcript or terminal dump" },
      },
    },
  };
  const names = { question: "quicktty_ask_user", action: "quicktty_confirm_action", notify: "quicktty_notify" };
  const descriptions = {
    question: "Ask the user a necessary question through connected QuickTTY/Telegram and wait for their answer. If unavailable, ask locally. Never send secrets, terminal dumps or transcripts.",
    action: "Request one-time user approval for an exact action through connected QuickTTY/Telegram. This tool executes nothing and cannot bypass native permissions or other user restrictions. Denied, expired or unavailable is NOT approval.",
    notify: "Send a brief status through connected QuickTTY/Telegram. Accepted means queued, not proven delivery. Working does not notify the phone. Never send secrets or transcripts.",
  };
  for (const mode of ["question", "action", "notify"] as const) {
    pi.registerTool({
      name: names[mode], label: names[mode], description: descriptions[mode],
      promptSnippet: descriptions[mode],
      promptGuidelines: [
        `Use ${names[mode]} for ${mode === "question" ? "necessary user questions instead of ending the turn waiting for an answer when QuickTTY messaging is enabled" : mode === "action" ? "explicit one-time action approvals; do not execute unless the result is approved for exactly this unchanged action" : "a brief completion or failure notice when useful; do not report success without evidence"}.`,
        `Never send secrets through ${names[mode]}; do not retry a denied request, reuse an approval for another action, or bypass native harness permissions.`,
        ...(mode === "action" ? ["Call quicktty_confirm_action alone and wait for approved before issuing the protected action in a later model turn; never batch an action alongside its confirmation."] : []),
      ],
      parameters: schemas[mode], exposure: "model-only", executionMode: "sequential",
      async execute(toolCallID, raw: unknown, signal, _onUpdate, ctx) {
        const requestID = randomUUID();
        const result = (reply: MessagingReply) => ({
          content: [{ type: "text" as const, text: JSON.stringify(reply) }],
          details: reply, isError: reply.state === "error",
        });
        if (stopped || signal?.aborted) return result(failure(requestID, "cancelled"));
        if (blockedBatch) return result(failure(requestID, "invalidRequest"));
        if (active) return result(failure(requestID, "capacityExceeded"));
        let sessionID: string;
        try { sessionID = ctx.sessionManager.getSessionId(); }
        catch { return result(failure(requestID, "cancelled")); }
        if (!isBounded(sessionID, 512) || raw === null || typeof raw !== "object" || Array.isArray(raw)) return result(failure(requestID, "invalidRequest"));
        const params = raw as Record<string, unknown>;
        const textKey = mode === "question" ? "question" : mode === "action" ? "operation" : "summary";
        const maximum = mode === "question" ? 2_304 : mode === "action" ? 1_024 : 512;
        if (typeof params[textKey] !== "string" || !isBounded(params[textKey] as string, maximum)) return result(failure(requestID, "invalidRequest"));
        const timeoutSeconds = params.timeoutSeconds ?? 900;
        if (!Number.isInteger(timeoutSeconds) || (timeoutSeconds as number) < 1 || (timeoutSeconds as number) > 1_800) return result(failure(requestID, "invalidRequest"));
        const request: MessagingRequest = { version: 1, operation: mode, requestID, sessionID, text: params[textKey] };
        if (mode === "question") {
          const choices = params.choices ?? [];
          if (!Array.isArray(choices) || choices.length > 8 || new Set(choices).size !== choices.length || !choices.every((value: unknown) => typeof value === "string" && isBounded(value, 64))) return result(failure(requestID, "invalidRequest"));
          request.choices = choices;
          request.timeoutMilliseconds = (timeoutSeconds as number) * 1_000;
        } else if (mode === "action") {
          if (typeof params.resources !== "string" || !isBounded(params.resources, 768) || typeof params.consequences !== "string" || !isBounded(params.consequences, 768) || (params.elevated !== undefined && typeof params.elevated !== "boolean")) return result(failure(requestID, "invalidRequest"));
          request.resources = params.resources;
          request.consequences = params.consequences;
          request.elevated = params.elevated ?? true;
          request.timeoutMilliseconds = (timeoutSeconds as number) * 1_000;
        } else {
          if (!["working", "waiting", "completed", "failed"].includes(params.status as string)) return result(failure(requestID, "invalidRequest"));
          request.status = params.status;
        }
        const key = `${sessionID}\0${names[mode]}\0${toolCallID}`;
        const payload = JSON.stringify({ ...request, requestID: undefined });
        const previous = cache.get(key);
        if (previous) {
          if (previous.payload !== payload) return result(failure(previous.request.requestID, "requestIDConflict"));
          if (previous.reply) return result(previous.reply);
        }
        if (!previous && cache.size >= 4_096) return result(failure(requestID, "capacityExceeded"));
        const original = previous?.request ?? request;
        const entry = previous ?? { payload, request: original, reply: undefined as MessagingReply | undefined };
        cache.set(key, entry);
        active = true;
        pending.set(original.requestID, original);
        try {
          const deadline = performance.now() + (timeoutSeconds as number) * 1_000;
          const status = () => message({ version: 1, operation: "status", requestID: original.requestID, sessionID }, signal);
          let reply = await message(original, signal);
          if (reply.code === "deliveryUncertain" || reply.code === "timedOut") reply = await status();
          while (reply.state === "pending" && !signal?.aborted && !stopped) {
            const remaining = Math.floor(deadline - performance.now());
            if (remaining < 100) { await cancel(original); reply = { version: 1, requestID: original.requestID, state: "expired" }; break; }
            reply = await message({ version: 1, operation: "wait", requestID: original.requestID, sessionID, timeoutMilliseconds: Math.min(30_000, remaining) }, signal);
            if (reply.code === "deliveryUncertain" || reply.code === "timedOut") reply = await status();
          }
          if (signal?.aborted || stopped) {
            await cancel(original);
            reply = failure(original.requestID, "cancelled");
          }
          if (mode === "question" && ["approved", "denied", "accepted"].includes(reply.state)) reply = failure(original.requestID, "deliveryUncertain");
          if (mode === "action" && ["text", "choice", "accepted"].includes(reply.state)) reply = failure(original.requestID, "deliveryUncertain");
          if (mode === "notify" && reply.state !== "accepted" && reply.state !== "error") reply = failure(original.requestID, "deliveryUncertain");
          entry.reply = reply;
          return result(reply);
        } catch {
          entry.reply = failure(original.requestID, "deliveryUncertain");
          return result(entry.reply);
        } finally {
          pending.delete(original.requestID);
          active = false;
        }
      },
    });
  }
  return { shutdown, observeBatch, guardCall };
}

export default function quickTTYSessionIntegration(pi: ExtensionAPI): void {
  let messaging: ReturnType<typeof installMessagingTools> | undefined;
  pi.on("message_end", (event) => {
    if (event.message.role !== "assistant") return;
    messaging?.observeBatch(event.message.content.filter((block) => block.type === "toolCall").map((block) => block.name));
  });
  pi.on("tool_call", () => messaging?.guardCall());
  pi.on("turn_end", () => { messaging?.observeBatch([]); });
  pi.on("session_start", async (_event, ctx) => {
    const sessionID = ctx.sessionManager.getSessionId();
    if (!isBounded(sessionID, 512) || !isBounded(ctx.cwd, 4_096)) return;

    const shared = state();
    const previousSessionID = shared.previousSessionID;
    shared.previousSessionID = undefined;
    shared.currentSessionID = sessionID;

    if (previousSessionID && isBounded(previousSessionID, 512)) {
      const accepted = await send("session_switch", {
        previous_session_id: previousSessionID,
        session_id: sessionID,
        cwd: ctx.cwd,
      });
      if (accepted) messaging ??= installMessagingTools(pi);
      return;
    }
    if (await send("session_start", { session_id: sessionID, cwd: ctx.cwd })) {
      messaging ??= installMessagingTools(pi);
    }
  });

  pi.on("session_shutdown", async (event, ctx) => {
    await messaging?.shutdown();
    messaging = undefined;
    const shared = state();
    const sessionID = shared.currentSessionID ?? ctx.sessionManager.getSessionId();
    if (!isBounded(sessionID, 512)) return;

    shared.currentSessionID = undefined;
    if (event.reason === "quit") {
      shared.previousSessionID = undefined;
      await send("session_shutdown", { session_id: sessionID, reason: "quit" });
      return;
    }
    if (event.reason === "new" || event.reason === "resume" || event.reason === "fork") {
      shared.previousSessionID = sessionID;
    }
  });
}
