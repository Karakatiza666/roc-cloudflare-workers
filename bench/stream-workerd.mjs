// PLAN.md 8b (second half), 9c, 10a, 10b in workerd: bench/app_stream.wasm behind `makeHandler` (bench/stream-worker.js,
// bench/config-stream.capnp, port 8136). The Node test is bench/stream-test.mjs.
// WORKERD=<path> node bench/stream-workerd.mjs
// Each check prints `FAIL <id>: ...` on a failure. Exit 1 on a failure.
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import net from 'node:net';
import { createHash } from 'node:crypto';
import zlib from 'node:zlib';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const PORT = 8136;
const BASE = `http://127.0.0.1:${PORT}`;
const MB = 2 ** 20;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = false;
const fail = (id, ...m) => {
  failed = true;
  console.log(`FAIL ${id}:`, ...m);
};
const json = async (path) => (await fetch(BASE + path)).json();
const stats = () => json('/__stats');
const marks = async () => (await json('/__marks')).marks;
const logLines = async () => (await json('/__log')).join(' | ');

// A body of `total` bytes in chunks of 64 KiB, made when the reader pulls. Byte i is i % 251.
const PAT = Uint8Array.from({ length: 65536 + 251 }, (_, i) => i % 251);
function bigStream(total) {
  let sent = 0;
  return new ReadableStream({
    pull(c) {
      if (sent >= total) return c.close();
      const n = Math.min(65536, total - sent);
      c.enqueue(PAT.slice(sent % 251, (sent % 251) + n));
      sent += n;
    },
  });
}
const post = (path, body) => fetch(BASE + path, { method: 'POST', body, duplex: 'half' });
// A POST of `total` bytes (as `bigStream`) with a raw socket: the text of the response. The app answers after its first
// chunk, and workerd then closes the connection while the client still sends: fetch of Node can give "terminated" then.
function rawPost(path, total) {
  return new Promise((resolve, reject) => {
    const s = net.connect(PORT, '127.0.0.1');
    let got = Buffer.alloc(0);
    let sent = 0;
    let done = false;
    const finish = (text) => {
      if (done) return;
      done = true;
      s.destroy();
      resolve(text);
    };
    const parse = () => {
      const at = got.indexOf('\r\n\r\n');
      if (at < 0) return;
      const len = Number(/content-length: *(\d+)/i.exec(got.subarray(0, at).toString())?.[1]);
      if (got.length >= at + 4 + len) finish(got.subarray(at + 4, at + 4 + len).toString());
    };
    const pump = () => {
      while (!done && sent < total) {
        const n = Math.min(65536, total - sent);
        const ok = s.write(PAT.subarray(sent % 251, (sent % 251) + n));
        sent += n;
        if (!ok) return s.once('drain', pump);
      }
    };
    s.on('connect', () => {
      s.write(`POST ${path} HTTP/1.1\r\nHost: x\r\nContent-Length: ${total}\r\n\r\n`);
      pump();
    });
    s.on('data', (d) => {
      got = Buffer.concat([got, d]);
      parse();
    });
    s.on('error', () => {});
    s.on('close', () => (done ? null : reject(new Error(`the connection closed: ${got.toString().slice(0, 200)}`))));
  });
}

// An old workerd on the port would answer for this one.
if (await fetch(BASE + '/ping').then(() => true, () => false)) {
  console.log(`FAIL run: port ${PORT} is in use`);
  process.exit(1);
}
const p = spawn(process.env.WORKERD, ['serve', join(here, 'config-stream.capnp')], { stdio: ['ignore', 'ignore', 'pipe'] });
let stderr = '';
p.stderr.on('data', (d) => (stderr += d));
try {
  let up = false;
  for (let i = 0; i < 100 && !up; i++) {
    await sleep(100);
    try {
      up = (await fetch(BASE + '/ping')).ok;
    } catch {}
  }
  if (!up) throw new Error(`workerd did not start: ${stderr.slice(-400)}`);
  // Warm-up.
  await (await post('/pipe', bigStream(MB))).arrayBuffer();
  await (await post('/limit?max=100', 'x'.repeat(50))).text();

  // 10a: 50 MB through `Response` as a stream: wasm memory grows by less than 1 MB.
  {
    const m0 = (await stats()).mem;
    const res = await post('/pipe', bigStream(50 * MB));
    const rd = res.body.getReader();
    let n = 0;
    let good = true;
    for (;;) {
      const { done, value } = await rd.read();
      if (done) break;
      for (let i = 0; i < value.length; i += 997) if (value[i] !== (n + i) % 251) good = false;
      n += value.length;
    }
    const grew = (await stats()).mem - m0;
    console.log('10a pipe 50 MB:', { status: res.status, bytes: n, good, grewBytes: grew });
    if (res.status !== 200 || n !== 50 * MB || !good) fail('10a', `the body did not come back: ${n} bytes`);
    if (grew >= MB) fail('10a', `wasm memory grew by ${grew} bytes`);
  }

  // 10b: the first 1 KB of a 50 MB body (`chunk!`), and `bytes_with!` with 1 KB: wasm memory grows by less than 1 MB.
  {
    const m0 = (await stats()).mem;
    const text = await rawPost('/chunk?n=1024', 50 * MB);
    const limit = await rawPost('/limit?max=1024', 50 * MB);
    const grew = (await stats()).mem - m0;
    console.log('10b:', { text, limit, grewBytes: grew });
    if (!/^chunks=1 bytes=\d+$/.test(text) || limit !== 'TooLarge') fail('10b', `${text} ${limit}`);
    if (grew >= MB) fail('10b', `wasm memory grew by ${grew} bytes`);
  }

  // tee!, sha256! (crypto.DigestStream of workerd), compress! and decompress!.
  {
    const tee = await (await post('/tee', bigStream(100_000))).text();
    const data = Uint8Array.from({ length: 300_000 }, (_, i) => (i * 7919) & 255);
    const want = createHash('sha256').update(data).digest('hex');
    const sha = await (await post('/sha', data)).text();
    const input = new TextEncoder().encode('Roc on Workers, a line of text. '.repeat(6000));
    const gz = new Uint8Array(await (await post('/compress?f=gzip', input)).arrayBuffer());
    const back = new Uint8Array(await (await post('/decompress?f=deflate', zlib.deflateSync(input))).arrayBuffer());
    const same = (x) => Buffer.compare(Buffer.from(x), Buffer.from(input)) === 0;
    const gzOk = (() => {
      try {
        return same(zlib.gunzipSync(gz));
      } catch {
        return false;
      }
    })();
    console.log('tee, sha, compress:', { tee, sha: sha === want, gzip: gzOk, inflate: same(back) });
    if (!/^a=100000 b=100000 same=True again=BodyErr\(TypeError\)$/.test(tee)) fail('tee', tee);
    if (sha !== want) fail('sha', `${sha} want ${want}`);
    if (!gzOk || !same(back)) fail('compress', `gzip ${gzOk}, deflate ${same(back)}`);
  }

  // respond!: the response before the work after it.
  {
    const text = await (await fetch(BASE + '/after?id=a1')).text();
    const at = (await marks()).a1;
    await sleep(300);
    const later = (await marks()).a1;
    console.log('respond after:', { text, atResponse: at, later });
    if (text !== 'early' || at !== undefined || later?.[0] !== 'after') fail('after', `${text} ${at} ${later}`);
  }

  // A read of the request body after respond! gives BodyErr (API.md 10.2): the handler gives Err, a log line.
  {
    await logLines();
    const res = await post('/late?id=l1', bigStream(10_000));
    const text = await res.text();
    await sleep(400);
    const l = await logLines();
    console.log('read after respond!:', { text, log: l, mark: (await marks()).l1 });
    if (text !== 'early' || !/fetch: after respond: failed: BodyErr\(/.test(l) || (await marks()).l1) fail('late', `${text} ${l}`);
  }

  // Body.writer!: the client gets the first chunk before the task writes the second.
  {
    const t0 = performance.now();
    const res = await fetch(BASE + '/stream?id=s1&n=4&gap=150&after=0');
    const rd = res.body.getReader();
    const at = [];
    let text = '';
    try {
      for (;;) {
        const { done, value } = await rd.read();
        if (done) break;
        at.push(Math.round(performance.now() - t0));
        text += new TextDecoder().decode(value);
      }
    } catch (e) {
      text += `<the stream broke: ${e.name}>`;
    }
    console.log('writer:', { at, text: JSON.stringify(text) });
    if (text !== 'chunk 0\nchunk 1\nchunk 2\nchunk 3\n') fail('writer', `the stream is not whole: ${JSON.stringify(text)}`);
    if (!(at.length >= 4 && at[at.length - 1] - at[0] >= 350)) fail('writer', `the chunks came at once: ${at}`);
  }

  // 9c: Ctx.wait_until!: the started program runs after the response (in workerd a timer of a request stops with its
  // response when no waitUntil keeps it: research/stream-cancel/).
  {
    const text = await (await fetch(BASE + '/waituntil?id=w1&ms=100')).text();
    const at = (await marks()).w1;
    await sleep(400);
    const later = (await marks()).w1;
    const s = await stats();
    console.log('wait_until:', { text, atResponse: at, later, contexts: s.contextsLive, refs: s.refsLive });
    if (text !== 'ok' || at !== undefined || later?.[0] !== 'started') fail('waituntil', `${text} ${at} ${later}`);
  }

  // A client that goes away from an open writer stream (a TCP reset after the first chunk): the task is cancelled once
  // (PLAN.md 3, "a wait that never settles after respond! while a stream is open"). The first event cancels it:
  // workerd 2026-10-12 aborts only request.signal (reason `signal`). workerd 2026-10-23 also cancels the response
  // stream (as the edge, E11), and that comes first (reason `stream`). request.signal alone: signal-workerd.mjs.
  {
    const cancels = (s) => (s.byReason.signal ?? 0) + (s.byReason.stream ?? 0);
    const before = cancels(await stats());
    await new Promise((resolve) => {
      const s = net.connect(PORT, '127.0.0.1');
      s.on('connect', () => s.write('GET /stream?id=s2&n=100&gap=50&after=0 HTTP/1.1\r\nHost: x\r\n\r\n'));
      s.on('data', (d) => {
        if (String(d).includes('chunk 0')) {
          s.resetAndDestroy();
          resolve();
        }
      });
      s.on('error', () => {});
    });
    await sleep(500);
    const s = await stats();
    console.log('client goes away:', { cancels: cancels(s) - before, byReason: s.byReason, mark: (await marks()).s2, tasks: s.tasks });
    if (cancels(s) - before !== 1 || (await marks()).s2) fail('away', 'the writer task was not cancelled when the client went away');
  }

  const s = await stats();
  console.log('end:', s);
  if (s.live !== 0 || s.tasks !== 0 || s.refsLive !== 0 || s.contextsLive !== 0 || s.alarms !== 0) fail('end', JSON.stringify(s));
} catch (e) {
  fail('run', String(e?.stack ?? e));
} finally {
  // workerd waits for the requests in flight at SIGTERM: SIGKILL after 2 s.
  if (p.exitCode === null && p.signalCode === null) {
    const exited = once(p, 'exit');
    p.kill();
    const timer = setTimeout(() => p.kill('SIGKILL'), 2000);
    await exited;
    clearTimeout(timer);
  }
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
