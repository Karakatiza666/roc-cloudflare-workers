// `Body.chunk!` and `chunk_with!` (MODULES.md 4, "Chunks"): routes of conformance/BodyRoutes.roc. The body is the body
// of `Http.open!` of the local server (`/big`, `/drip`: byte i is i % 251), or the request body.
// The fill rule: JS adds each next part that is ready to the chunk, to `fill_bytes` (default 64 KiB). Only the first
// part of a chunk is a wait, so a slow stream gives each part when it comes.
import { ok } from '../assert.mjs';

export const options = {};

const KB = 1024;
// The answer of a route: { sizes, at, bytes, bad, again }.
const parse = (r) => {
  ok(r.status === 200, `status ${r.status}: ${r.body.slice(0, 300)}`);
  const m = /^sizes=([\d,]*) at=([\d,]*) bytes=(\d+) bad=(\d+) again=(\S+)$/.exec(r.body);
  ok(m, `answer: ${r.body.slice(0, 300)}`);
  const list = (s) => (s ? s.split(',').map(Number) : []);
  return { sizes: list(m[1]), at: list(m[2]), bytes: Number(m[3]), bad: Number(m[4]), again: m[5], awaits: r.awaits };
};
const open = async (t, path, q = '') => parse(await t.get(`/body/open?url=${encodeURIComponent(t.server + path)}${q}`));
// The bytes and their order, the End and the call after End.
const whole = (g, n) => {
  ok(g.bytes === n && g.sizes.reduce((a, b) => a + b, 0) === n, `bytes ${g.bytes}, want ${n}`);
  ok(g.bad === 0, `${g.bad} bytes not in their place`);
  ok(g.again === 'End', `the call after End gave ${g.again}`);
};
const show = (g) => `${g.sizes.length} chunks (${Math.min(...g.sizes)} to ${Math.max(...g.sizes)} B), ${g.awaits} waits`;

export const checks = [
  // A fast body of 4 MiB: workerd gives parts of about 4 KiB, `chunk!` fills them to 64 KiB. A part that is not ready
  // at the timer makes a smaller chunk, so the check takes a mean of 32 KiB or more (4 KiB parts: 4 KiB).
  ['body chunk!: a fast stream fills each chunk to 64 KiB, with one wait for each chunk', async (t) => {
    const n = 4 * KB * KB;
    const g = await open(t, `/big?n=${n}`);
    whole(g, n);
    ok(g.sizes.every((s) => s <= KB * KB), `a chunk over default_max: ${Math.max(...g.sizes)}`);
    ok(n / g.sizes.length >= 32 * KB, `mean chunk ${Math.round(n / g.sizes.length)} B, want 32 KiB or more: ${show(g)}`);
    ok(g.awaits <= g.sizes.length + 3, `${g.awaits} waits for ${g.sizes.length} chunks`);
    return show(g);
  }],
  // `fill_bytes: 1`: each part as JS gives it (the parts of workerd: 4 KiB or less).
  ['body chunk_with! fill_bytes 1: each part of the stream as JS gives it', async (t) => {
    const n = 1 * KB * KB;
    const g = await open(t, `/big?n=${n}`, '&fill=1');
    whole(g, n);
    ok(Math.max(...g.sizes) <= 16 * KB && g.sizes.length >= n / (16 * KB), `want parts of 16 KiB or less: ${show(g)}`);
    return show(g);
  }],
  // `max_bytes` cuts a chunk, and the rest comes at the next call. `fill_bytes` larger than `max_bytes`: the fill stops at `max_bytes`.
  ['body chunk_with! max_bytes: no chunk is larger, the rest comes next, fill_bytes over max_bytes stops at max_bytes', async (t) => {
    const n = 1 * KB * KB;
    const g = await open(t, `/big?n=${n}`, '&fill=1000000&max=10000');
    whole(g, n);
    ok(Math.max(...g.sizes) === 10000, `want chunks of at most 10000 B, and some of 10000: ${show(g)}`);
    const small = await open(t, `/big?n=${n}`, '&max=3000');
    whole(small, n);
    ok(Math.max(...small.sizes) === 3000, `max only: ${show(small)}`);
    const zero = await open(t, `/big?n=100`, '&max=0');
    whole(zero, 100);
    ok(zero.sizes.length === 100, `max_bytes 0 is 1: ${show(zero)}`);
    return `${show(g)}; max 3000: ${show(small)}`;
  }],
  // A slow stream: 5 parts of 100 B, 400 ms between them. The call does not wait for 64 KiB: it gives each part when
  // it comes (the next part is not ready at the timer). Each chunk comes about 400 ms after the one before.
  ['body chunk!: a slow stream gives each part when it comes, the call does not wait for fill_bytes', async (t) => {
    const g = await open(t, '/drip?parts=5&size=100&gap=400');
    whole(g, 500);
    ok(g.sizes.join() === '100,100,100,100,100', `sizes ${g.sizes.join()}`);
    ok(g.at[0] < 300, `the first chunk at ${g.at[0]} ms, want before the second part (400 ms)`);
    for (let i = 1; i < g.at.length; i++) ok(g.at[i] - g.at[i - 1] >= 250, `chunk ${i} at ${g.at[i]} ms, the one before at ${g.at[i - 1]} ms`);
    return `at ${g.at.join(', ')} ms`;
  }],
  // A fill stops when the next part is not ready, and that read stays for the next call: `bytes!` after one chunk gives
  // all the rest, in order.
  ['body chunk! then bytes!: the read that a fill left is the start of the rest', async (t) => {
    const r = await t.get(`/body/mixed?url=${encodeURIComponent(`${t.server}/drip?parts=3&size=100&gap=200`)}`);
    ok(r.status === 200 && r.body === 'first=100 rest=200 bad=0', `${r.status} ${r.body}`);
    return r.body;
  }],
  // The request body (a stream of the request), and the bodies that are not streams. The request comes from Node at the
  // speed of the local socket, so the count of chunks follows the timing: 5 with wrangler 4.151, 8 or 9 with 4.158. With
  // no fill (one part for each call), it is about 75.
  ['body chunk!: the request body, an empty body, the end', async (t) => {
    const n = 300 * KB;
    const body = Uint8Array.from({ length: n }, (_, i) => i % 251);
    const g = parse(await t.get('/body/read', { method: 'POST', body }));
    whole(g, n);
    ok(g.sizes.length <= 16, `${show(g)}`);
    const e = parse(await t.get('/body/read', { method: 'POST' }));
    ok(e.sizes.length === 0 && e.again === 'End', `an empty body: ${JSON.stringify(e)}`);
    return show(g);
  }],
];
