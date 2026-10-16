// Small asserts for the check files: each throws an Error with the text that `run.mjs` prints after FAIL.
export function eq(got, want, what = 'the answer') {
  if (got !== want) throw new Error(`${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
}
export function ok(cond, why) {
  if (!cond) throw new Error(why);
}
// A 200 answer with the body `want`.
export function answer(r, want) {
  if (r.status !== 200 || r.body !== want) throw new Error(`got ${r.status} ${JSON.stringify(r.body.slice(0, 300))}, want 200 ${JSON.stringify(want)}`);
}
