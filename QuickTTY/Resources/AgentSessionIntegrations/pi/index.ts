import { spawn } from "node:child_process";
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

async function send(event: string, payload: Record<string, string>): Promise<void> {
  const input = Buffer.from(JSON.stringify(payload), "utf8");
  if (input.byteLength > MAXIMUM_PAYLOAD_BYTES) return;

  await new Promise<void>((resolve) => {
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const finish = (): void => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolve();
    };
    const child = spawn(HELPER_PATH, ["internal", "hook", "pi", event], {
      shell: false,
      stdio: ["pipe", "ignore", "ignore"],
    });
    timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish();
    }, HELPER_TIMEOUT_MS);
    child.once("error", finish);
    child.once("close", finish);
    child.stdin.once("error", finish);
    child.stdin.end(input);
  });
}

export default function quickTTYSessionIntegration(pi: ExtensionAPI): void {
  pi.on("session_start", async (_event, ctx) => {
    const sessionID = ctx.sessionManager.getSessionId();
    if (!isBounded(sessionID, 512) || !isBounded(ctx.cwd, 4_096)) return;

    const shared = state();
    const previousSessionID = shared.previousSessionID;
    shared.previousSessionID = undefined;
    shared.currentSessionID = sessionID;

    if (previousSessionID && isBounded(previousSessionID, 512)) {
      await send("session_switch", {
        previous_session_id: previousSessionID,
        session_id: sessionID,
        cwd: ctx.cwd,
      });
      return;
    }
    await send("session_start", { session_id: sessionID, cwd: ctx.cwd });
  });

  pi.on("session_shutdown", async (event, ctx) => {
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
