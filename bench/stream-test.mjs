// PLAN.md 8b (second half), 9c, 10a, 10b in Node: stream bodies (API.md RS3), `Ctx.respond!` and its rules (API.md
// 10.2), `Ctx.pass_through!`, `Body.writer!`, `compress!`, `decompress!`, `Ctx.wait_until!` and `Io.start!` (RS1).
// The app is bench/app_stream.roc. workerd: bench/stream-workerd.mjs. Reverts: bench/stream-reverts.mjs.
// node bench/stream-test.mjs bench/out/app_stream.wasm
// Each check prints `FAIL <id>: ...` on a failure. Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import zlib from 'node:zlib';
import { makeHandler } from './cf-node.mjs';

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
let failed = false;
const fail = (id, ...m) => {
  failed = true;
  console.log(`FAIL ${id}:`, ...m);
};
const MB = 2 ** 20;
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

// The ops of the app (bench/app_stream.roc).
const marks = new Map(); // id -> [text]
const puts = new Map(); // key -> { length, sha }
const lines = []; // { text, at }
const ops = {
  // A wait of `ms` that stops with an AbortError when the signal aborts (OP8).
  sleep: (ms, signal) =>
    new Promise((resolve, reject) => {
      const onAbort = () => {
        clearTimeout(timer);
        reject(signal.reason);
      };
      const timer = setTimeout(() => {
        signal?.removeEventListener('abort', onAbort);
        resolve(ms);
      }, ms);
      if (signal?.aborted) onAbort();
      else signal?.addEventListener('abort', onAbort, { once: true });
    }),
  mark: (id, text) => {
    marks.set(id, [...(marks.get(id) ?? []), text]);
  },
  // A stand-in for a `Cache.named` put (no Cache module yet, PLAN.md 8c): it reads the stream to its end.
  put: async (key, stream) => {
    const bytes = new Uint8Array(await new Response(stream).arrayBuffer());
    puts.set(key, { length: bytes.length, sha: createHash('sha256').update(bytes).digest('hex') });
  },
  boom: () => {
    throw new TypeError('boom of the test');
  },
  one: () => 1,
};
const log = (text) => lines.push({ text, at: performance.now() });
// H: the default deadlines. HD: the 30 s limit after the response at 100 ms (API.md 10.2, PLAN.md 3b). No idle check
// (12e): it gives its own promise to ctx.waitUntil, and the test counts the promises of wait_until!.
const H = makeHandler(module, { ops, log, isolateBytes: 2 ** 40, heapCheckWhenIdle: false });
const HD = makeHandler(module, { ops, log, isolateBytes: 2 ** 40, heapCheckWhenIdle: false, afterRespondMs: 100 });
const pending = [];
const ctx = {
  waitUntil(p) {
    pending.push(p);
  },
  passThroughOnException() {
    this.passed = true;
  },
};
const settle = async () => {
  while (pending.length) await pending.shift();
};
const get = (Handler, path, init) => new Handler(ctx, { name: 'env' }).fetch(new Request(`http://x${path}`, init));
const post = (Handler, path, body) => get(Handler, path, { method: 'POST', body, duplex: 'half' });
const logSince = (n) => lines.slice(n).map((l) => l.text).join(' | ');

// A body of `total` bytes in chunks of 64 KiB, made when the reader pulls (as from the network). Byte i is i % 251.
const PAT = Uint8Array.from({ length: 65536 + 251 }, (_, i) => i % 251);
function bigStream(total, counter = { pulled: 0 }) {
  let sent = 0;
  return new ReadableStream({
    pull(c) {
      if (sent >= total) return c.close();
      const n = Math.min(65536, total - sent);
      c.enqueue(PAT.slice(sent % 251, (sent % 251) + n));
      sent += n;
      counter.pulled += n;
    },
  });
}
// Reads a response body: its length, and whether byte i is i % 251.
async function readPattern(res) {
  const rd = res.body.getReader();
  let n = 0;
  let good = true;
  for (;;) {
    const { done, value } = await rd.read();
    if (done) break;
    for (let i = 0; i < value.length; i += 997) if (value[i] !== (n + i) % 251) good = false;
    n += value.length;
  }
  return { n, good };
}
const memOf = (Handler) => Handler.runner.x.memory.buffer.byteLength;

// Warm-up: the instance and its first requests.
await (await post(H, '/pipe', bigStream(MB))).arrayBuffer();
await (await post(H, '/limit?max=100', 'x'.repeat(50))).text();

// 10a: a 50 MB request body through `Response` as a stream. wasm memory grows by less than 1 MB.
{
  const m0 = memOf(H);
  const res = await post(H, '/pipe', bigStream(50 * MB));
  const r = await readPattern(res);
  const grew = memOf(H) - m0;
  console.log('10a pipe 50 MB:', { status: res.status, bytes: r.n, good: r.good, grewBytes: grew });
  if (res.status !== 200 || r.n !== 50 * MB || !r.good) fail('10a', `the body did not come back: ${r.n} bytes, good ${r.good}`);
  if (grew >= MB) fail('10a', `wasm memory grew by ${grew} bytes`);
}

// 10b: the first 1 KB of a 50 MB body (`chunk!`), and `bytes_with!` with a limit of 1 KB: wasm memory grows by less
// than 1 MB, and JS reads only the chunks that Roc asks for.
{
  const m0 = memOf(H);
  const counter = { pulled: 0 };
  const text = await (await post(H, '/chunk?n=1024', bigStream(50 * MB, counter))).text();
  const grew = memOf(H) - m0;
  console.log('10b chunk:', { text, pulled: counter.pulled, grewBytes: grew });
  if (text !== 'chunks=1 bytes=65536') fail('10b', `chunk!: ${text}`);
  if (grew >= MB) fail('10b', `chunk!: wasm memory grew by ${grew} bytes`);
  const m1 = memOf(H);
  const limit = await (await post(H, '/limit?max=1024', bigStream(50 * MB))).text();
  const grew2 = memOf(H) - m1;
  const small = await (await post(H, '/limit?max=100', 'y'.repeat(50))).text();
  console.log('10b limit:', { limit, small, grewBytes: grew2 });
  if (limit !== 'TooLarge' || small !== 'ok 50') fail('10b', `bytes_with!: ${limit}, ${small}`);
  if (grew2 >= MB) fail('10b', `bytes_with!: wasm memory grew by ${grew2} bytes`);
}

// tee!: two streams with the same bytes. A second read of the first body is `BodyErr` (RS3).
{
  const text = await (await post(H, '/tee', bigStream(100_000))).text();
  console.log('tee:', text);
  if (!/^a=100000 b=100000 same=(True|Bool\.True) again=BodyErr\(TypeError\)$/.test(text)) fail('tee', text);
}

// sha256!: the stream in JS, and the bytes in wasm, give the SHA-256 of Node.
{
  const data = Uint8Array.from({ length: 300_000 }, (_, i) => (i * 7919) & 255);
  const want = createHash('sha256').update(data).digest('hex');
  const s = await (await post(H, '/sha', data)).text();
  const b = await (await post(H, '/sha?bytes=1', data)).text();
  console.log('sha:', { stream: s === want, bytes: b === want });
  if (s !== want || b !== want) fail('sha', `${s} ${b} want ${want}`);
}

// compress!, decompress!: Node zlib decodes the output to the input, and decompress! of it gives the input.
{
  const input = new TextEncoder().encode('Roc on Workers, a line of text. '.repeat(6000) + 'end');
  for (const [f, unzip, zip] of [['gzip', zlib.gunzipSync, zlib.gzipSync], ['deflate', zlib.inflateSync, zlib.deflateSync]]) {
    // A body that breaks (a stream error) is its error text.
    const bytesOf = async (path, body) => {
      try {
        return new Uint8Array(await (await post(H, path, body)).arrayBuffer());
      } catch (e) {
        return `${e.name}: ${e.message}`;
      }
    };
    const out = await bytesOf(`/compress?f=${f}`, input);
    let byZlib;
    try {
      byZlib = new Uint8Array(unzip(out));
    } catch (e) {
      byZlib = String(e);
    }
    const back = await bytesOf(`/decompress?f=${f}`, out);
    const back2 = await bytesOf(`/decompress?f=${f}`, zip(input));
    const eq = (x) => x instanceof Uint8Array && Buffer.compare(Buffer.from(x), Buffer.from(input)) === 0;
    console.log(`compress ${f}:`, { in: input.length, out: out.length, zlib: eq(byZlib), back: eq(back), fromZlib: eq(back2) });
    if (!(out.length < input.length / 10) || !eq(byZlib)) fail('compress', `${f}: zlib did not decode the output to the input`);
    if (!eq(back) || !eq(back2)) fail('compress', `${f}: decompress! did not give the input (${back.length ?? back}, ${back2.length ?? back2})`);
  }
}

// Response.after: the response goes out at once, and the work after it runs after the response (in ctx.waitUntil).
{
  const res = await get(H, '/after?id=a1');
  const text = await res.text();
  const atResponse = marks.get('a1');
  await settle();
  console.log('respond after:', { text, atResponse, after: marks.get('a1') });
  if (text !== 'early' || atResponse !== undefined) fail('after', `the response came at the task end: ${text}, marks ${atResponse}`);
  if (marks.get('a1')?.[0] !== 'after') fail('after', 'the work of after did not run');
}

// Two after calls: the work of each, in order.
{
  const text = await (await get(H, '/twice?id=t1')).text();
  await settle();
  console.log('after twice:', text, marks.get('t1'));
  if (text !== 'first' || marks.get('t1')?.join(',') !== 'one,two') fail('twice', `${text} ${marks.get('t1')}`);
}

// pass_through! in a Scheduled event gives InvalidState.
for (const cron of ['pass']) {
  const n = lines.length;
  let got;
  try {
    await new H(ctx, {}).scheduled({ cron, scheduledTime: 1, noRetry() {} });
    got = 'ok';
  } catch (e) {
    got = `throw ${e.message}`;
  }
  console.log(`scheduled ${cron}:`, got, logSince(n));
  if (got !== 'ok') fail('scheduled', `${cron}: ${got} ${logSince(n)}`);
}

// pass_through!: then an Err makes the fetch handler throw (Workers sends the request to the origin). A crash too.
for (const path of ['/pass', '/passcrash']) {
  ctx.passed = false;
  let got;
  try {
    got = `status ${(await get(H, path)).status}`;
  } catch (e) {
    got = `throw ${e.message}`;
  }
  console.log(`pass ${path}:`, got, { passThroughOnException: ctx.passed });
  if (!got.startsWith('throw') || !ctx.passed) fail('pass', `${path}: ${got}, passThroughOnException ${ctx.passed}`);
}

// Requests every 25 ms, so the shim runs its deadline sweep (PLAN.md 3b: no timer).
const pinging = (Handler, ms) => {
  const end = performance.now() + ms;
  return (async () => {
    while (performance.now() < end) {
      await (await get(Handler, '/ping')).text();
      await wait(25);
    }
  })();
};
const cancels = (Handler, reason) => Handler.runner.tasks.stats.byReason[reason] ?? 0;

// After respond! (the limit at 100 ms): a task with a Bytes body that then waits 300 ms is cancelled.
{
  const c0 = cancels(HD, 'deadline');
  const res = await get(HD, '/deadline?id=d1&ms=300');
  await res.arrayBuffer();
  await pinging(HD, 400);
  await settle();
  console.log('deadline after respond!:', { cancels: cancels(HD, 'deadline') - c0, mark: marks.get('d1') });
  if (cancels(HD, 'deadline') - c0 !== 1 || marks.get('d1')) fail('deadline', `not cancelled: ${marks.get('d1')}`);
}

// Body.writer!: the client gets the first chunk before the task writes the second. The stream is open for 300 ms
// with the limit at 100 ms: not cancelled. A wait that starts after its close! is cancelled about 100 ms later.
{
  const c0 = cancels(HD, 'deadline');
  const t0 = performance.now();
  const res = await get(HD, '/stream?id=s1&n=4&gap=100&after=400');
  const ping = pinging(HD, 700);
  const rd = res.body.getReader();
  const got = [];
  let text = '';
  try {
    for (;;) {
      const { done, value } = await rd.read();
      if (done) break;
      got.push(Math.round(performance.now() - t0));
      text += new TextDecoder().decode(value);
    }
  } catch (e) {
    text += `<the stream broke: ${e.name}>`;
  }
  const closedAt = performance.now() - t0;
  await ping;
  await settle();
  const cancelLine = lines.find((l) => l.text.includes('task cancelled (deadline)') && l.at > t0);
  const cancelAfterClose = cancelLine ? Math.round(cancelLine.at - t0 - closedAt) : null;
  console.log('writer:', { chunksAt: got, text: JSON.stringify(text), closedAt: Math.round(closedAt), cancelAfterClose, mark: marks.get('s1') });
  if (text !== 'chunk 0\nchunk 1\nchunk 2\nchunk 3\n') fail('writer', `the stream is not whole: ${JSON.stringify(text)}`);
  if (!(got.length >= 4 && got[got.length - 1] - got[0] >= 250)) fail('writer', `the chunks came at once: ${got}`);
  if (cancels(HD, 'deadline') - c0 !== 1 || marks.get('s1')) fail('writer', `the wait after close! was not cancelled: ${marks.get('s1')}`);
  if (cancelAfterClose === null || cancelAfterClose < 60 || cancelAfterClose > 250) fail('writer', `the cancel came ${cancelAfterClose} ms after close!, want about 100`);
}

// A write! after close! gives BodyErr.
{
  await (await get(H, '/closed?id=c1')).text();
  await settle();
  console.log('write after close:', marks.get('c1'));
  if (!/^BodyErr\(/.test(marks.get('c1')?.[0] ?? '')) fail('closed', `${marks.get('c1')}`);
}

// The client cancels the stream: the task is cancelled at once (reason "stream").
{
  const c0 = cancels(H, 'stream');
  const res = await get(H, '/stream?id=s2&n=100&gap=50&after=0');
  const rd = res.body.getReader();
  await rd.read();
  const t0 = performance.now();
  await rd.cancel(new Error('the client went away'));
  await settle();
  const ms = Math.round(performance.now() - t0);
  console.log('stream cancel:', { cancels: cancels(H, 'stream') - c0, ms, mark: marks.get('s2') });
  if (cancels(H, 'stream') - c0 !== 1 || marks.get('s2')) fail('cancel', `the task was not cancelled by the stream cancel (${ms} ms)`);
  if (ms > 100) fail('cancel', `the task ended ${ms} ms after the cancel`);
}

// 9c: Ctx.wait_until!: the promise goes to ctx.waitUntil, and runs after the response. The context stays until it settles.
{
  const n = pending.length;
  const live0 = H.runner.tasks.stats.contextsLive;
  const text = await (await get(H, '/waituntil?id=w1&ms=100')).text();
  const atResponse = { mark: marks.get('w1'), waitUntil: pending.length - n, contexts: H.runner.tasks.stats.contextsLive - live0 };
  await settle();
  console.log('wait_until:', text, atResponse, { mark: marks.get('w1'), contexts: H.runner.tasks.stats.contextsLive - live0 });
  if (text !== 'ok' || atResponse.mark || atResponse.waitUntil !== 1 || atResponse.contexts !== 1) fail('waituntil', JSON.stringify(atResponse));
  if (marks.get('w1')?.[0] !== 'started' || H.runner.tasks.stats.contextsLive !== live0) fail('waituntil', `after: ${marks.get('w1')}`);
}

// 9c: a started program waits 100 ms (with the signal of its task), then reads the Stream body of the request and puts it
// (a stand-in for a Cache.named put), after its task returned. The put is done, then the ref table of the task is empty.
{
  const n = lines.length;
  const data = Uint8Array.from({ length: 300_000 }, (_, i) => (i * 31) & 255);
  const text = await (await post(H, '/started?key=k1', data)).text();
  const atResponse = { put: puts.get('k1'), refs: H.runner.tasks.stats.refsLive, contexts: H.runner.tasks.stats.contextsLive };
  await settle();
  const want = createHash('sha256').update(data).digest('hex');
  const after = { put: puts.get('k1'), refs: H.runner.tasks.stats.refsLive, contexts: H.runner.tasks.stats.contextsLive, log: logSince(n) };
  console.log('started program:', text, atResponse, after);
  if (atResponse.put || atResponse.refs < 1 || atResponse.contexts !== 1) fail('started', `at the response: ${JSON.stringify(atResponse)}`);
  if (after.put?.sha !== want || after.put?.length !== data.length) fail('started', `the put was not done: ${after.log}`);
  if (after.refs !== 0 || after.contexts !== 0) fail('started', `the ref table is not empty: ${after.refs} refs, ${after.contexts} contexts`);
  if (after.log) fail('started', `a log line: ${after.log}`);
}

// 9c: a started program that throws gives one log line. One that gives a Roc-level Err gives no log line (MODULES.md 11).
{
  let n = lines.length;
  await (await get(H, '/startthrow')).text();
  await settle();
  const thrown = lines.slice(n).map((l) => l.text);
  n = lines.length;
  await (await get(H, '/starterr')).text();
  await settle();
  const err = lines.slice(n).map((l) => l.text);
  console.log('started throw, Err:', { thrown, err });
  if (thrown.length !== 1 || !/started program failed.*TypeError: boom of the test/.test(thrown[0])) fail('startlog', `throw: ${thrown}`);
  if (err.length !== 0) fail('startlog', `Err: ${err}`);
}

// 9c: the 30 s waitUntil limit (here 100 ms): the context of a started program that waits 400 ms is freed at the limit,
// and its wait sees the abort. The work after the wait does not run.
{
  const n = lines.length;
  const t0 = performance.now();
  await (await get(HD, '/waituntil?id=w2&ms=400')).text();
  await pinging(HD, 300);
  await settle();
  const freed = lines.slice(n).find((l) => l.text.includes('task context freed at the waitUntil limit'));
  const at = freed ? Math.round(freed.at - t0) : null;
  console.log('waitUntil limit:', { freedAt: at, mark: marks.get('w2'), log: logSince(n), contexts: HD.runner.tasks.stats.contextsLive });
  if (!freed || at > 250 || marks.get('w2')) fail('linger', `the context was not freed at the limit: ${at} ms, mark ${marks.get('w2')}`);
  if (HD.runner.tasks.stats.contextsLive !== 0 || HD.runner.tasks.stats.refsLive !== 0) fail('linger', 'contexts or refs left');
}

for (const [name, Handler] of [['H', H], ['HD', HD]]) {
  const r = Handler.runner;
  const end = { live: r.x.live_bytes(), tasks: r.tasks.size, refs: r.tasks.stats.refsLive, contexts: r.tasks.stats.contextsLive, alarms: r.stats.alarms };
  console.log(`end ${name}:`, end);
  if (end.live !== 0 || end.tasks !== 0 || end.refs !== 0 || end.contexts !== 0 || end.alarms !== 0) fail('end', `${name}: ${JSON.stringify(end)}`);
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
