import fs from "node:fs";

export const QuickTTYPlugin = async () => ({
  event: async ({ event }) => {
    if (event.type !== "session.created") return;
    const descriptor = Number.parseInt(process.env.QUICKTTY_WRAPPER_IDENTITY_FD ?? "", 10);
    const sessionID = event.properties?.info?.id;
    if (!Number.isInteger(descriptor) || typeof sessionID !== "string") return;
    const payload = Buffer.from(JSON.stringify({
      adapterID: "opencode",
      cwd: process.cwd(),
      sessionID,
    }));
    const header = Buffer.alloc(4);
    header.writeUInt32BE(payload.length);
    fs.writeSync(descriptor, Buffer.concat([header, payload]));
  },
});
