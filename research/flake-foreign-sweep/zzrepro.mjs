// Repro: a sweep by a request of another context does not end a waiting Init task (cancel at 1 s, the wait ends at 6 s).
// Use: cp research/flake-foreign-sweep/zzrepro.mjs conformance/checks/ && node conformance/run.mjs bench/out/conformance.wasm "ZZ foreign sweep"; rm conformance/checks/zzrepro.mjs
// The deadline of Slow.init is 1000 ms (initMs), its tick is at 1050 ms. A request at 1020 ms to 1040 ms calls tasks.sweep() first (js/runner.js run).
// Expected: about 1060 ms for each. Seen: 6004 ms for 1020, 1030 and 1040 (and 1112 ms for 1010: the tick cancels).
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const checks = [];
for (const d of [1010, 1020, 1030, 1040]) {
  checks.push([`ZZ foreign sweep ${d}`, async (t) => {
    const p = t.get(`/objects/slow?name=zz${d}`);
    await sleep(d);
    await t.get('/objects/counter?name=zzother&op=get');
    const r = await p;
    if (r.ms > 4500) throw new Error(`the cancel at the sweep did not end the wait: ${r.ms} ms`);
    return `${r.ms} ms`;
  }]);
}
