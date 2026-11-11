// Probes of the wasm32 dev trap with roc-cbor 0.5.0 (research/cbor-0.5.0, local branch cbor-0.5.0 only).
// Each check prints the status and the body of one probe route.
export const options = {};
const show = async (t, p) => { const r = await t.get(p); return `${r.status} ${r.body.slice(0, 200)}`; };
export const checks = [];
for (const s of ['rr1', 'rr_u64', 'rr_u8', 'rr_str', 'rr_bytes_type', 'rec_bytes', 'list_bytes', 'tup_mat']) {
  checks.push([`cborprobe shape ${s}`, (t) => show(t, `/memo/probe/shape/${s}?n=1`)]);
}
for (const [i, len] of [[0, 1], [1, 1]]) {
  checks.push([`cborprobe jwk i=${i} len=${len}`, (t) => show(t, `/memo/probe/jwk?i=${i}&len=${len}`)]);
}
