// Scan one wasm function: calls, i32.const values that point into data segments, and the strings there.
// Usage: node wasmscan.mjs app.wasm [funcIndex|big] [mode]
import { readFileSync } from 'node:fs';
const b = readFileSync(process.argv[2]);
let p = 8;
const u = () => { let r = 0, s = 0, x; do { x = b[p++]; r += (x & 0x7f) * 2 ** s; s += 7; } while (x & 0x80); return r; };
const s32 = () => { let r = 0n, s = 0n, x; do { x = b[p++]; r |= BigInt(x & 0x7f) << s; s += 7n; } while (x & 0x80); if (s < 64n && (x & 0x40)) r |= (-1n << s); return r; };
const name = () => { const n = u(); const t = b.subarray(p, p + n).toString('utf8'); p += n; return t; };
const imports = [], exports = {}, bodies = [], data = []; let funcTypes = [];
while (p < b.length) {
  const id = b[p++], size = u(), end = p + size;
  if (id === 2) { const n = u(); for (let i = 0; i < n; i++) { const m = name(), f = name(); const k = b[p++];
      if (k === 0) { u(); imports.push(m + '.' + f); } else if (k === 1) { p++; const fl = u(); u(); if (fl & 1) u(); } else if (k === 2) { const fl = u(); u(); if (fl & 1) u(); } else { p += 2; } } }
  if (id === 7) { const n = u(); for (let i = 0; i < n; i++) { const nm = name(); const k = b[p++]; const ix = u(); if (k === 0) exports[ix] = nm; } }
  if (id === 10) { const n = u(); for (let i = 0; i < n; i++) { const s = u(); bodies.push([p, p + s]); p += s; } }
  if (id === 11) { const n = u(); for (let i = 0; i < n; i++) { const fl = u(); let off = 0;
      if (fl === 0 || fl === 2) { if (fl === 2) u(); const op = b[p++]; off = Number(s32()); p++; }
      const len = u(); data.push({ off, start: p, len }); p += len; } }
  p = end;
}
const NI = imports.length; let constPos = [], callPos = [];
const at = (addr) => { for (const d of data) if (addr >= d.off && addr < d.off + d.len) return d.start + (addr - d.off); return -1; };
// Decode function body: returns { calls: Map, consts: [] }
function scan(fi) {
  const [s, e] = bodies[fi - NI]; p = s;
  const nl = u(); for (let i = 0; i < nl; i++) { u(); p++; }
  const calls = new Map(), consts = [], ind = []; constPos = []; callPos = [];
  let ops = 0;
  while (p < e) {
    const op = b[p++]; ops++;
    if (op === 0x10) { const at0 = p - 1; const f = u(); calls.set(f, (calls.get(f) || 0) + 1); callPos.push([at0, f]); }
    else if (op === 0x11) { u(); u(); ind.push(1); }
    else if (op === 0x41) { const at0 = p - 1; consts.push(Number(BigInt.asIntN(32, s32()))); constPos.push(at0); }
    else if (op === 0x42) s32();
    else if (op === 0x43) p += 4; else if (op === 0x44) p += 8;
    else if (op === 0x02 || op === 0x03 || op === 0x04) { const t = b[p]; if (t === 0x40 || t >= 0x6f) p++; else s32(); }
    else if (op === 0x0c || op === 0x0d) u();
    else if (op === 0x0e) { const n = u(); for (let i = 0; i <= n; i++) u(); }
    else if (op >= 0x20 && op <= 0x24) u();
    else if (op === 0x25 || op === 0x26) u();
    else if (op >= 0x28 && op <= 0x3e) { u(); u(); }
    else if (op === 0x3f || op === 0x40) p++;
    else if (op === 0x1c) { const n = u(); p += n; }
    else if (op === 0xd0) p++; else if (op === 0xd2) u();
    else if (op === 0xfc) { const sub = u(); if (sub <= 7) {} else if (sub === 8) { u(); p++; } else if (sub === 9) u(); else if (sub === 10) { p += 2; } else if (sub === 11) p++; else if (sub >= 12 && sub <= 17) { u(); if (sub === 12 || sub === 14) u(); } }
    else if (op === 0xfd) { const sub = u(); if (sub <= 11 || sub === 92 || sub === 93) { u(); u(); } else if (sub === 12 || sub === 13) p += 16; else if (sub >= 21 && sub <= 34) p++; else if (sub >= 84 && sub <= 91) { u(); u(); p++; } }
    else if (![0x00,0x01,0x05,0x0b,0x0f,0x1a,0x1b,0xd1].includes(op) && !(op >= 0x45 && op <= 0xc4)) throw new Error('unknown op ' + op.toString(16) + ' at ' + p);
    // else: no immediates
  }
  return { calls, consts, ops, ind: ind.length };
}
const sizes = bodies.map(([s, e], i) => [NI + i, e - s]).sort((a, c) => c[1] - a[1]);
const arg = process.argv[3] || 'big';
const fi = arg === 'big' ? sizes[0][0] : Number(arg);
const mode = process.argv[4] || 'strings';
if (process.argv[3]==='top') { const N=Number(process.argv[4]||15); const callers=new Map(); for (let g=NI; g<NI+bodies.length; g++){ const q=scan(g); for (const f of q.calls.keys()) { if(!callers.has(f)) callers.set(f,[]); callers.get(f).push(g);} } let tot=0; for (const [f,sz] of sizes.slice(0,N)) { const q=scan(f); const strs=new Set(); for (const c of q.consts) { const o=at(c>>>0); if (o<0||c<1024) continue; let t=''; for (let i=o;i<o+28&&i<b.length;i++){const ch=b[i]; if(ch===0)break; t+=ch>=32&&ch<127?String.fromCharCode(ch):'.';} if(!/^Integer/.test(t)) strs.add(t);} tot+=sz; console.log(f+'\t'+sz+'\tops '+q.ops+'\tcallers '+(callers.get(f)||[]).join(',')+'\tcallees '+q.calls.size+'\tstrings '+strs.size+' '+[...strs].slice(0,3).join(' | ')); } console.log('sum', tot); process.exit(0); }
if (process.argv[3]==='anc') { const callers=new Map(); for (let g=NI; g<NI+bodies.length; g++){ const q=scan(g); for (const f of q.calls.keys()) { if(!callers.has(f)) callers.set(f,[]); callers.get(f).push(g);} }
 for (const root of process.argv.slice(4).map(Number)) { const seen=new Set([root]); let fr=[root]; const out=[]; for (let d=0; d<4; d++){ const nx=[]; for (const f of fr) for (const c of callers.get(f)||[]) if(!seen.has(c)){seen.add(c); nx.push(c); const q=scan(c); const strs=new Set(); for (const k of q.consts){const o=at(k>>>0); if(o<0||k<1024)continue; let t=''; for(let i=o;i<o+30&&i<b.length;i++){const ch=b[i]; if(ch===0)break; t+=ch>=32&&ch<127?String.fromCharCode(ch):'.';} if(!/^Integer/.test(t)) strs.add(t);} out.push('  d'+d+' f'+c+' size '+(bodies[c-NI][1]-bodies[c-NI][0])+' '+[...strs].slice(0,4).join(' | '));} fr=nx; } console.log('root',root); console.log(out.join('\n')); } process.exit(0); }
const r = scan(fi);
console.log(`imports ${NI} funcs ${bodies.length} target ${fi} size ${bodies[fi - NI][1] - bodies[fi - NI][0]} ops ${r.ops} indirect ${r.ind} exports-of-target ${exports[fi] || '-'}`);
if (mode === 'consts') { const m=new Map(); r.consts.forEach(c=>m.set(c,(m.get(c)||0)+1)); for (const [c,n] of [...m].sort((a,b)=>b[1]-a[1]).slice(0,30)) console.log(c, '0x'+(c>>>0).toString(16), n); }
else if (mode === 'pos') {
  // offsets (from body start) of each i32.const equal to argv[5]
  const want = Number(process.argv[5]); const base = bodies[fi - NI][0]; const xs = [];
  r.consts.forEach((c, i) => { if (c === want) xs.push(constPos[i] - base); });
  console.log(xs.join(' '));
} else if (mode === 'map') {
  // timeline: per window of W bytes, the strings that the window points to (problem table strings left out)
  const W = Number(process.argv[5] || 20000); const base = bodies[fi - NI][0]; const win = new Map();
  const str = (c) => { const o = at(c >>> 0); let t = ''; for (let i = o; i < o + 40 && i < b.length; i++) { const ch = b[i]; if (ch === 0) break; t += ch >= 32 && ch < 127 ? String.fromCharCode(ch) : '.'; } return t; };
  r.consts.forEach((c, i) => { if (c < 1024 || at(c >>> 0) < 0) return; if (c >= 1068177 && c <= 1070230) return; const w = Math.floor((constPos[i] - base) / W); if (!win.has(w)) win.set(w, new Map()); const m = win.get(w); const t = str(c); m.set(t, (m.get(t) || 0) + 1); });
  const prob = new Map(); r.consts.forEach((c, i) => { if (c === 1069792) { const w = Math.floor((constPos[i] - base) / W); prob.set(w, (prob.get(w) || 0) + 1); } });
  for (let w = 0; w * W < bodies[fi - NI][1] - base; w++) { const m = win.get(w) || new Map(); console.log(`${w * W}\tproblem-copies=${prob.get(w) || 0}\t` + [...m].filter(([t]) => !/^(Internal error|content-type|application\/problem\+json|Integer)/.test(t)).map(([t, n]) => t.slice(0, 30) + (n > 1 ? 'x' + n : '')).join(' | ')); }
} else if (mode === 'dump') {
  // calls and data strings between offsets argv[5] and argv[6] of the body
  const lo = Number(process.argv[5]), hi = Number(process.argv[6]); const base = bodies[fi - NI][0]; const ev = [];
  const str = (c) => { const o = at(c >>> 0); let t = ''; for (let i = o; i < o + 30 && i < b.length; i++) { const ch = b[i]; if (ch === 0) break; t += ch >= 32 && ch < 127 ? String.fromCharCode(ch) : '.'; } return t; };
  r.consts.forEach((c, i) => { const q = constPos[i] - base; if (q >= lo && q < hi && c >= 1024 && at(c >>> 0) >= 0) ev.push([q, 'str ' + c + ' ' + JSON.stringify(str(c))]); });
  callPos.forEach(([q0, f]) => { const q = q0 - base; if (q >= lo && q < hi) ev.push([q, 'call ' + f + ' (' + (f < NI ? imports[f] : bodies[f - NI][1] - bodies[f - NI][0]) + ')']); });
  ev.sort((a, c) => a[0] - c[0]); for (const e of ev) console.log(e[0] + '\t' + e[1]);
} else if (mode === 'calls') {
  const rows = [...r.calls].map(([f, n]) => [f, n, f < NI ? imports[f] : (bodies[f - NI][1] - bodies[f - NI][0]), exports[f] || '']).sort((a, c) => c[1] - a[1]);
  console.log('distinct callees', rows.length); for (const x of rows) console.log(x.join('\t'));
} else if (mode === 'callers') {
  for (let g = NI; g < NI + bodies.length; g++) { const q = scan(g); if (q.calls.has(fi)) console.log('caller', g, bodies[g - NI][1] - bodies[g - NI][0], exports[g] || ''); }
} else {
  const seen = new Map();
  for (const c of r.consts) { const o = at(c >>> 0); if (o < 0 || c < 1024) continue; seen.set(c, (seen.get(c) || 0) + 1); }
  console.log('consts into data', seen.size);
  for (const [c, n] of [...seen].sort((a, c2) => a[0] - c2[0])) {
    const o = at(c >>> 0); let t = ''; for (let i = o; i < o + 80 && i < b.length; i++) { const ch = b[i]; if (ch === 0) break; t += ch >= 32 && ch < 127 ? String.fromCharCode(ch) : '.'; }
    console.log(c, n, JSON.stringify(t));
  }
}
