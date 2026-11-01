// node run.mjs app.wasm: call wasm_main of the roc test/wasm platform and print the Str it returns.
import { readFileSync } from "node:fs";
let mem;
const text = (p, n) => new TextDecoder().decode(new Uint8Array(mem.buffer, p, n));
const env = new Proxy({}, { get: (_, name) => (p, n) => {
	if (name === "echo") return;
	console.log(`${String(name)}(${typeof p === "number" && typeof n === "number" ? text(p, n) : ""})`);
} });
const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), { env });
mem = instance.exports.memory;
const p = instance.exports.wasm_main();
console.log(text(p, instance.exports.wasm_result_len()));
