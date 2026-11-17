#!/usr/bin/env node
// Report to AgentBar from Node.js over its local socket. Run with: node emit.mjs
import net from "node:net";
import os from "node:os";
import path from "node:path";

const SOCK = path.join(os.homedir(), "Library/Application Support/AgentBar/agentbar.sock");

function send(event) {
  return new Promise((resolve) => {
    const s = net.createConnection(SOCK);
    let buf = "";
    s.on("error", () => resolve({ ok: false, error: "AgentBar is not running" }));
    s.on("data", (d) => (buf += d));
    s.on("end", () => resolve(JSON.parse(buf.split("\n")[0] || "{}")));
    s.end(JSON.stringify(event) + "\n");
  });
}

const session = "node-" + Math.random().toString(36).slice(2, 8);
console.log(await send({ v: 1, agent: "my-agent", session_id: session, event: "started", title: "node example" }));
console.log(await send({ v: 1, agent: "my-agent", session_id: session, event: "needs_input",
                         message: "Which environment should I deploy to?" }));
