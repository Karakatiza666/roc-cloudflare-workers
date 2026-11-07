// Micro traces for the cost of one kind of call (scripts/pstat.mjs on out/trace_micro_<kind>.bin).
// node micro.mjs   -> out/trace_micro_{af,chain,task,mixf}.bin
// af: alloc then free of a 32 B block, one task, 1 M pairs (the fast path; the page stays).
// lifo: 64 live blocks of 24 to 182 B, then free all, 16 K times (a page fills and empties).
// chain: 25 -> 46 -> 93 -> 182 B by realloc, then free, 250 K times (the bench app's strings).
// task: 100 K tasks, each 8 allocs of 8 classes, a wait, 8 frees, task end (fixed cost of a request).
import { writeFileSync } from 'node:fs';
const A = 1 | (4 << 8), R = 3 | (4 << 8);
const gen = (kind, f) => { const b = []; f((op, owner, id, len) => b.push(op, owner, id, len)); const u = new Uint32Array(b); writeFileSync(new URL(`../out/trace_micro_${kind}.bin`, import.meta.url), u); console.log(kind, u.length / 4, 'records'); };
gen('af', (p) => { for (let i = 0; i < 1e6; i++) { p(A, 1, 0, 32); p(2, 1, 0, 0); } p(4, 1, 0, 0); });
gen('lifo', (p) => { const S = [24, 40, 60, 90, 120, 182]; for (let k = 0; k < 16384; k++) { for (let j = 0; j < 64; j++) p(A, 1, j, S[j % 6]); for (let j = 63; j >= 0; j--) p(2, 1, j, 0); } p(4, 1, 0, 0); });
gen('chain', (p) => { for (let i = 0; i < 250000; i++) { p(A, 1, 0, 25); p(R, 1, 0, 46); p(R, 1, 0, 93); p(R, 1, 0, 182); p(2, 1, 0, 0); } p(4, 1, 0, 0); });
gen('task', (p) => { const S = [16, 32, 48, 64, 96, 128, 192, 256]; for (let t = 1; t <= 100000; t++) { for (let j = 0; j < 8; j++) p(A, t, j, S[j]); p(5, t, 0, 0); for (let j = 0; j < 8; j++) p(2, t, j, 0); p(4, t, 0, 0); } });
