// Usage: node wasmfuncs.mjs file.wasm > funcs.tsv   (build with `roc build --debug`: it adds the name section)
// One line for each function: index, bytes (with the size prefix), name, tag, kind.
//   tag  = number of distinct infrastructure tag names ("KvEr", "D1Er", ...) that the code loads as small-string constants
//   kind = writer (CBOR writer of a union: many list appends), inspect (Str.inspect of a union: escape_and_quote), or ''
// The Roc names are hashes (roc__p<hash>.fast), so the kind comes from the code, not from the name.
import fs from 'fs';
const b = fs.readFileSync(process.argv[2]); let p = 8;
const leb = () => { let r = 0, s = 0, x; do { x = b[p++]; r += (x & 127) * 2 ** s; s += 7 } while (x & 128); return r };
const sleb = () => { let r = 0n, s = 0n, x; do { x = b[p++]; r |= BigInt(x & 127) << s; s += 7n } while (x & 128); if (x & 64) r -= 1n << s; return Number(BigInt.asIntN(32, r)) };
const secs = {}; let nImp = 0;
while (p < b.length) {
  const id = b[p++], sz = leb(), st = p; let nm = '';
  if (id === 0) { const l = leb(); nm = b.toString('utf8', p, p + l); p += l }
  if (id === 2) { const n = leb(); for (let i = 0; i < n; i++) { let l = leb(); p += l; l = leb(); p += l; const k = b[p++]; if (k === 0) { leb(); nImp++ } else if (k === 1) { p++; const f = leb(); leb(); if (f & 1) leb() } else if (k === 2) { const f = leb(); leb(); if (f & 1) leb() } else if (k === 3) { p += 2 } } }
  secs[id === 0 ? 'n:' + nm : id] = [st, st + sz, p]; p = st + sz;
}
const names = {};
if (secs['n:name']) {
  const [, en, p0] = secs['n:name']; p = p0;
  while (p < en) { const sid = b[p++], sz = leb(), e = p + sz; if (sid === 1) { const c = leb(); for (let i = 0; i < c; i++) { const idx = leb(), l = leb(); names[idx] = b.toString('utf8', p, p + l); p += l } } p = e }
}
const TAGS = new Set(['KvEr', 'D1Er', 'R2Er', 'Stor', 'SqlE', 'Cons', 'BadD', 'TooL', 'Time', 'Obje', 'RpcE', 'Serv', 'Netw', 'Sock', 'Cach', 'Queu', 'Http', 'Body', 'Cryp', 'AiEr', 'Emai', 'Asse', 'Limi', 'Miss', 'Inva']);
// Walk the opcodes of one function body [s, e): count calls by callee and find the tag constants.
function scan(s, e) {
  p = s; const nl = leb(); for (let i = 0; i < nl; i++) { leb(); p++ }
  const calls = new Map(), tags = new Set();
  while (p < e) {
    const op = b[p++];
    if (op === 0x02 || op === 0x03 || op === 0x04) { if (b[p] === 0x40 || (b[p] >= 0x6f && b[p] <= 0x7f)) p++; else sleb() }
    else if (op === 0x0c || op === 0x0d || op === 0x20 || op === 0x21 || op === 0x22 || op === 0x23 || op === 0x24 || op === 0x25 || op === 0x26 || op === 0xd2) leb();
    else if (op === 0x0e) { const n = leb(); for (let i = 0; i <= n; i++) leb() }
    else if (op === 0x10) { const f = leb(); calls.set(f, (calls.get(f) || 0) + 1) }
    else if (op === 0x11) { leb(); leb() }
    else if (op === 0x1c) { const n = leb(); p += n }
    else if (op >= 0x28 && op <= 0x3e) { leb(); leb() }
    else if (op === 0x3f || op === 0x40 || op === 0xd0) p++;
    else if (op === 0x41) { const v = sleb(); const t = Buffer.alloc(4); t.writeInt32LE(v); const s4 = t.toString('latin1'); if (TAGS.has(s4)) tags.add(s4) }
    else if (op === 0x42) { sleb64() }
    else if (op === 0x43) p += 4;
    else if (op === 0x44) p += 8;
    else if (op === 0xfc) { const sub = leb(); if (sub === 8) { leb(); p++ } else if (sub === 10) p += 2; else if (sub === 11) p++; else if (sub === 12 || sub === 14) { leb(); leb() } else if (sub >= 9 && sub <= 17) leb() }
    else if (op === 0xfd) {
      const sub = leb();
      if (sub <= 0x0b || sub === 0x5c || sub === 0x5d) { leb(); leb() }
      else if (sub === 0x0c || sub === 0x0d) p += 16;
      else if (sub >= 0x15 && sub <= 0x22) p++;
      else if (sub >= 0x54 && sub <= 0x5b) { leb(); leb(); p++ }
    }
  }
  return { calls, tags };
}
function sleb64() { let x; do { x = b[p++] } while (x & 128) }
const [cs] = secs[10]; p = cs; const n = leb();
const rows = [];
for (let i = 0; i < n; i++) {
  const a = p; const sz = leb(); const body = p, end = p + sz;
  const { calls, tags } = scan(body, end);
  const cnt = (re) => { let t = 0; for (const [f, c] of calls) if (re.test(names[f] || '')) t += c; return t };
  let kind = '';
  if (tags.size >= 10 && cnt(/list_reserve_for_append/) >= 20) kind = 'writer';
  else if (tags.size >= 10 && cnt(/str_escape_and_quote/) >= 5) kind = 'inspect';
  rows.push(`${i + nImp}\t${end - a}\t${names[i + nImp] || ''}\t${tags.size}\t${kind}`);
  p = end;
}
console.log(rows.join('\n'));
