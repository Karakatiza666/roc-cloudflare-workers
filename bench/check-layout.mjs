// Memory layout check of a linked wasm: is the shadow stack below the data?
// Usage: node bench/check-layout.mjs [--header <platform/main.roc>] <app.wasm>...
// Exit 0: all stack-first. 1: a file is data-first. 2: a file could not be checked.
// With --header, the stack size (the start of `__stack_pointer`) must equal `initial_stack_size`
// in the header. A missing field, or a stack of another size, is exit 1 (verdict STACK-SIZE).
// Stack-first: `__stack_pointer` starts at or below the lowest active data segment,
// so an overflow goes below address 0 and traps. Data-first: an overflow writes over data.
import { readFileSync } from 'node:fs';

const args = process.argv.slice(2);
let expectedStack = null;
const h = args.indexOf('--header');
if (h >= 0) {
  const m = /^\s*initial_stack_size:\s*(\d+)\s*,/m.exec(readFileSync(args[h + 1], 'utf8'));
  expectedStack = m ? Number(m[1]) : NaN;
  args.splice(h, 2);
}

function parse(buf) {
  let p = 8;
  const byte = () => buf[p++];
  const uleb = () => {
    let r = 0n, s = 0n, b;
    do { b = buf[p++]; r |= BigInt(b & 0x7f) << s; s += 7n; } while (b & 0x80);
    return Number(r);
  };
  const sleb = () => {
    let r = 0n, s = 0n, b;
    do { b = buf[p++]; r |= BigInt(b & 0x7f) << s; s += 7n; } while (b & 0x80);
    if (b & 0x40) r -= 1n << s;
    return Number(r);
  };
  const name = () => { const n = uleb(); const s = buf.toString('utf8', p, p + n); p += n; return s; };
  const limits = () => { const f = uleb(); uleb(); if (f & 1) uleb(); };
  // A constant expression: an i32.const value, or null for anything else.
  const constExpr = () => {
    let v = null, n = 0;
    for (let op = byte(); op !== 0x0b; op = byte(), n++) {
      if (op === 0x41) v = sleb();
      else if (op === 0x42) { sleb(); v = null; }
      else if (op === 0x23) { uleb(); v = null; }
      else throw new Error(`const expr opcode 0x${op.toString(16)}`);
    }
    return n === 1 ? v : null;
  };

  if (buf.readUInt32LE(0) !== 0x6d736100) throw new Error('not a wasm module');
  let importedGlobals = 0;
  const globals = [];
  const segments = [];
  const globalNames = new Map();
  while (p < buf.length) {
    const id = byte();
    const size = uleb();
    const end = p + size;
    if (id === 2) {
      for (let i = uleb(); i > 0; i--) {
        name(); name();
        const kind = byte();
        if (kind === 0) uleb();
        else if (kind === 1) { byte(); limits(); }
        else if (kind === 2) limits();
        else if (kind === 3) { byte(); byte(); importedGlobals++; }
        else if (kind === 4) { byte(); uleb(); }
        else throw new Error(`import kind ${kind}`);
      }
    } else if (id === 6) {
      for (let i = uleb(); i > 0; i--) {
        const type = byte();
        const mut = byte();
        globals.push({ type, mut, init: constExpr() });
      }
    } else if (id === 11) {
      for (let i = uleb(); i > 0; i--) {
        const flags = uleb();
        let offset = null;
        if (flags === 0) offset = constExpr();
        else if (flags === 2) { uleb(); offset = constExpr(); }
        const len = uleb();
        p += len;
        if (flags !== 1) segments.push({ offset, len });
      }
    } else if (id === 0 && name() === 'name') {
      // Global names (subsection 7), when the module is not stripped.
      while (p < end) {
        const sub = byte();
        const subSize = uleb();
        const subEnd = p + subSize;
        if (sub === 7) {
          for (let i = uleb(); i > 0; i--) { const idx = uleb(); globalNames.set(idx, name()); }
        }
        p = subEnd;
      }
    }
    p = end;
  }
  return { importedGlobals, globals, segments, globalNames };
}

// The stack pointer: the global named `__stack_pointer`, else the first defined
// mutable i32 global (wasm-ld puts `__stack_pointer` first and strips names).
function stackPointer(m) {
  for (const [idx, n] of m.globalNames) {
    if (n === '__stack_pointer') return { init: m.globals[idx - m.importedGlobals]?.init, how: 'name' };
  }
  const g = m.globals.find((g) => g.type === 0x7f && g.mut === 1);
  return g ? { init: g.init, how: 'first mutable i32 global' } : null;
}

let worst = 0;
for (const file of args) {
  let verdict, detail;
  try {
    const m = parse(readFileSync(file));
    const sp = stackPointer(m);
    const offsets = m.segments.map((s) => s.offset);
    if (!sp || sp.init == null) { verdict = 'UNKNOWN'; detail = 'no __stack_pointer with a constant start'; }
    else if (offsets.some((o) => o == null)) { verdict = 'UNKNOWN'; detail = 'a data segment has no constant offset'; }
    else if (offsets.length === 0) { verdict = 'UNKNOWN'; detail = `no active data segment (stack pointer ${sp.init})`; }
    else {
      const lo = Math.min(...offsets);
      const hi = Math.max(...m.segments.map((s) => s.offset + s.len));
      verdict = sp.init <= lo ? 'STACK-FIRST' : 'DATA-FIRST';
      detail = `stack pointer starts at ${sp.init} (${sp.how}), data ${lo}..${hi}`;
      if (verdict === 'STACK-FIRST' && expectedStack !== null && sp.init !== expectedStack) {
        verdict = 'STACK-SIZE';
        detail += Number.isNaN(expectedStack) ? ', and the header has no initial_stack_size' : `, but the header says initial_stack_size ${expectedStack}`;
      }
    }
  } catch (e) {
    verdict = 'UNKNOWN'; detail = String(e.message ?? e);
  }
  const code = verdict === 'STACK-FIRST' ? 0 : verdict === 'DATA-FIRST' || verdict === 'STACK-SIZE' ? 1 : 2;
  worst = Math.max(worst, code);
  console.log(`${verdict} ${file}: ${detail}`);
}
if (args.length < 1) { console.log('usage: node bench/check-layout.mjs [--header <main.roc>] <app.wasm>...'); worst = 2; }
process.exit(worst);
