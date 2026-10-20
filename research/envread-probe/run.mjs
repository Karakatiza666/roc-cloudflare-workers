// node research/envread-probe/run.mjs <app.wasm>: OTHER is read twice, the shim warns once. KV is declared: no warning.
import { readFileSync } from 'node:fs';
import { makeHandler } from '../../bench/cf-node.mjs';
const lines = [];
const H = makeHandler(new WebAssembly.Module(readFileSync(process.argv[2])), { log: (t) => lines.push(t) });
// A real binding is a class instance, not a plain object.
class Ns { async get() { return null; } async put() {} async getWithMetadata() { return {}; } async list() { return {}; } async delete() {} }
const kvEnv = new Ns();
const env = { KV: kvEnv, OTHER: kvEnv };
for (let i = 0; i < 2; i++) await new H({ waitUntil() {} }, env).fetch(new Request('http://x/'));
console.log(lines.filter((l) => l.includes('reads the binding')));
