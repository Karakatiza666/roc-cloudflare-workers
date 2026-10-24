// Ask a roc-syntax-mcp server with the cloudflare-workers plugin what a caller gets (skill Step 8b).
// Usage: node ask.mjs <workspace dir> <tool> '<json args>' [<tool> '<json args>' ...]
// Raw JSON-RPC over stdio, one message per line.
import { spawn } from "node:child_process";
import readline from "node:readline";
const repo = "/home/george/dev/Karakatiza666/roc-syntax-mcp";
const [cwd, ...rest] = process.argv.slice(2);
const srv = spawn("node", ["--import", `${repo}/node_modules/tsx/dist/esm/index.mjs`, `${repo}/src/index.ts`, `--plugin=${repo}/plugins/cloudflare-workers`], { cwd, stdio: ["pipe", "pipe", "inherit"], env: { ...process.env, NODE_PATH: `${repo}/node_modules` } });
const waits = new Map();
readline.createInterface({ input: srv.stdout }).on("line", (l) => {
  const m = JSON.parse(l);
  if (m.id !== undefined && waits.has(m.id)) { waits.get(m.id)(m); waits.delete(m.id); }
});
let id = 0;
const send = (method, params) => new Promise((ok) => { const i = ++id; waits.set(i, ok); srv.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: i, method, params }) + "\n"); });
await send("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "ask", version: "0" } });
srv.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
for (let i = 0; i < rest.length; i += 2) {
  const r = await send("tools/call", { name: rest[i], arguments: JSON.parse(rest[i + 1]) });
  const text = r.error ? JSON.stringify(r.error) : r.result.content.map((x) => x.text ?? "").join("\n");
  console.log(`### ${rest[i]} ${rest[i + 1]}\n${text.slice(0, 1200)}\n`);
}
srv.kill();
