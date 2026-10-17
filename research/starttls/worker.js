// PLAN.md 11c, EP6: why does a `tls: StartTls` socket wait with no end after its first read on the edge (E47)?
// Three levels of the same steps (a banner, EHLO, STARTTLS, a TLS upgrade, EHLO). The first level that hangs names the cause:
//   /raw   `connect` of `cloudflare:sockets`, one reader and one writer, no shim.     Hang here: the runtime (or the proxy).
//   /shim  the helpers of the shim (`tcpConnect`, `tcpRead`, `tcpWrite`, `tcpStartTls`).  Hang here, not in /raw: the shim.
//   (the full platform: `/edge/starttls` of edge/EdgeRoutes.roc, a Roc program under JSPI.)
// Each step has a timeout (STEP_MS), so a hang is a line `timeout`, not a request that never ends. After a timeout the steps stop.
// Query: host, port, and for /raw: mode=starttls|off, half=false|true|none (allowHalfOpen), relock=1 (a new reader and writer
// for each step), upgrade=0 (stop before `startTls()`), early=1 (write EHLO before the banner is read), locked=1 (the reader and
// the writer stay locked at `startTls()`).
import { makeHelpers } from './js/helpers.js';

const STEP_MS = 5000;
const enc = new TextEncoder();
const dec = new TextDecoder();

// Runs the steps `[name, fn]` one after the other. A step that takes more than STEP_MS is a `timeout`, and the run stops.
async function run(steps) {
  const out = [];
  const t0 = Date.now();
  for (const [name, fn] of steps) {
    const s0 = Date.now();
    let to;
    const timer = new Promise((r) => (to = setTimeout(() => r({ timeout: true }), STEP_MS)));
    try {
      const v = await Promise.race([fn().then((v) => ({ v })), timer]);
      clearTimeout(to);
      if (v.timeout) {
        out.push({ step: name, ms: Date.now() - s0, result: 'timeout' });
        break;
      }
      out.push({ step: name, ms: Date.now() - s0, result: 'ok', value: v.v });
    } catch (e) {
      clearTimeout(to);
      out.push({ step: name, ms: Date.now() - s0, result: 'throw', error: `${e.name}: ${e.message}` });
      break;
    }
  }
  return { total_ms: Date.now() - t0, steps: out };
}

// An SMTP reply is one or more lines; the last one has a space after the code (`250 ...`, not `250-...`). The reads are in
// chunks, and a chunk can hold more than one reply (the server wrote the banner and the answer at once), so `replies(read)`
// keeps the text that is left. `read` gives bytes, or undefined at the end of the socket.
function replies(read) {
  let rest = '';
  return async () => {
    for (;;) {
      const m = /^(?:\d{3}-[^\r\n]*\r\n)*\d{3} [^\r\n]*\r\n/.exec(rest);
      if (m) {
        rest = rest.slice(m[0].length);
        return m[0].split('\r\n')[0] + (m[0].includes('-') && m[0].indexOf('-') === 3 ? ' (+ more lines)' : '');
      }
      const v = await read();
      if (v === undefined) return 'done';
      rest += dec.decode(v);
    }
  };
}

// Level 1: the raw socket.
async function raw(q) {
  const { connect } = await import('cloudflare:sockets');
  const host = q.get('host');
  const port = Number(q.get('port'));
  const mode = q.get('mode') ?? 'starttls';
  const half = q.get('half') ?? 'false';
  const relock = q.get('relock') === '1';
  const opts = { secureTransport: mode };
  if (half !== 'none') opts.allowHalfOpen = half === 'true';
  let socket;
  let reader = null;
  let writer = null;
  const chunk = async () => {
    if (relock || !reader) {
      reader?.releaseLock();
      reader = socket.readable.getReader();
    }
    const r = await reader.read();
    return r.done ? undefined : r.value;
  };
  let read = replies(chunk);
  const write = async (text) => {
    if (relock || !writer) {
      writer?.releaseLock();
      writer = socket.writable.getWriter();
    }
    await writer.write(enc.encode(text));
    return 'written';
  };
  const steps = [
    ['connect', async () => ((socket = connect({ hostname: host, port }, opts)), 'made')],
    ['opened', async () => ((await socket.opened), 'opened')],
  ];
  if (q.get('early') === '1') steps.push(['write EHLO (before the banner)', () => write('EHLO probe.test\r\n')]);
  steps.push(['read banner', read]);
  if (q.get('early') !== '1') steps.push(['write EHLO', () => write('EHLO probe.test\r\n')]);
  steps.push(
    ['read EHLO answer', read],
    ['write STARTTLS', () => write('STARTTLS\r\n')],
    ['read STARTTLS answer', read],
  );
  if (q.get('upgrade') !== '0') {
    steps.push(
      ['startTls()', async () => {
        // locked=1: the reader and the writer stay locked (the shim keeps them), as a platform socket has them.
        if (q.get('locked') !== '1') {
          reader?.releaseLock();
          writer?.releaseLock();
        }
        reader = writer = null;
        socket = socket.startTls();
        read = replies(chunk);
        return 'called';
      }],
      ['opened (TLS)', async () => ((await socket.opened), 'opened')],
      ['write EHLO (TLS)', () => write('EHLO probe.test\r\n')],
      ['read EHLO answer (TLS)', read],
    );
  }
  const res = await run(steps);
  // No await: a close with a locked stream can wait with no end (the `locked=1` variant).
  try { socket?.close().catch(() => {}); } catch {}
  return res;
}

// Level 2: the helpers of the shim, as the platform calls them. `pf.tcpRead` gives bytes or undefined; no `signal`.
async function shim(q) {
  const pf = makeHelpers({}, {}, {}, {});
  const host = q.get('host');
  const port = Number(q.get('port'));
  let socket;
  const read = replies(() => pf.tcpRead(socket, 65536, undefined));
  const write = async (text) => (await pf.tcpWrite(socket, enc.encode(text))) ?? 'written';
  const steps = [
    ['connect (tcpConnect, starttls)', async () => ((socket = await pf.tcpConnect(host, port, q.get('mode') ?? 'starttls')), 'opened')],
    ['read banner', read],
    ['write EHLO', () => write('EHLO probe.test\r\n')],
    ['read EHLO answer', read],
    ['write STARTTLS', () => write('STARTTLS\r\n')],
    ['read STARTTLS answer', read],
  ];
  if (q.get('upgrade') !== '0') {
    steps.push(
      ['tcpStartTls', async () => ((socket = await pf.tcpStartTls(socket)), 'opened')],
      ['write EHLO (TLS)', () => write('EHLO probe.test\r\n')],
      ['read EHLO answer (TLS)', read],
    );
  }
  const res = await run(steps);
  try { pf.tcpClose(socket); } catch {}
  return res;
}

export default {
  async fetch(req) {
    const u = new URL(req.url);
    const q = u.searchParams;
    try {
      if (u.pathname === '/raw') return Response.json(await raw(q));
      if (u.pathname === '/shim') return Response.json(await shim(q));
    } catch (e) {
      return Response.json({ error: `${e.name}: ${e.message}` });
    }
    return new Response('routes: /raw /shim (query: host, port, mode, half, relock, upgrade, early)\n', { status: 404 });
  },
};
