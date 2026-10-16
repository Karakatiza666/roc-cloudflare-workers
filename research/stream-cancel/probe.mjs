// WORKERD=<path> node research/stream-cancel/probe.mjs
// For each config (with and without the flag enable_request_signal): the client reads 2 chunks of /stream, then goes
// away: an abort of fetch (a FIN), or a TCP reset of a raw socket. Then the records of the worker after 1 s.
// Also: a timer after the response with and without ctx.waitUntil.
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import net from 'node:net';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function withWorkerd(cfg, port, f) {
  const p = spawn(process.env.WORKERD, ['serve', join(here, cfg)], { stdio: ['ignore', 'ignore', 'pipe'] });
  let err = '';
  p.stderr.on('data', (d) => (err += d));
  const base = `http://127.0.0.1:${port}`;
  try {
    for (let i = 0; i < 100; i++) {
      await sleep(100);
      try { if ((await fetch(base + '/events')).ok) break; } catch {}
    }
    await f(base, port);
  } finally {
    p.kill();
    await once(p, 'exit');
  }
}

// A raw HTTP/1.1 client: read until 2 KB of body came, then a TCP reset (or a FIN with end()).
function rawClient(port, path, how) {
  return new Promise((resolve) => {
    const s = net.connect(port, '127.0.0.1');
    let n = 0;
    s.on('connect', () => s.write(`GET ${path} HTTP/1.1\r\nHost: x\r\n\r\n`));
    s.on('data', (d) => {
      n += d.length;
      if (n > 2300) {
        if (how === 'rst') s.resetAndDestroy();
        else s.destroy();
        resolve(n);
      }
    });
    s.on('error', () => {});
  });
}

const events = async (base, id) => (await fetch(`${base}/events?id=${id}`)).json();
const out = {};
for (const [cfg, port] of [['config-flag.capnp', 8241], ['config-noflag.capnp', 8242]]) {
  await withWorkerd(cfg, port, async (base) => {
    const r = {};
    for (const [name, path, how] of [
      ['fetch abort (FIN), waitUntil', '/stream', 'fetch'],
      ['TCP reset, waitUntil', '/stream', 'rst'],
      ['socket destroy, waitUntil', '/stream', 'fin'],
      ['TCP reset, no waitUntil', '/stream-nowait', 'rst'],
    ]) {
      const id = `${name.replace(/\W+/g, '-')}`;
      const q = `${path}?id=${id}&n=50&gap=100`;
      if (how === 'fetch') {
        const ac = new AbortController();
        const res = await fetch(base + q, { signal: ac.signal });
        const rd = res.body.getReader();
        let n = 0;
        while (n < 2048) n += (await rd.read()).value.length;
        ac.abort();
      } else await rawClient(port, q, how);
      await sleep(1000);
      r[name] = await events(base, id);
    }
    {
      // The whole body, then the client closes its socket (FIN) and a raw client resets (RST).
      for (const how of ['fin', 'rst']) {
        const id = `after-${how}`;
        await new Promise((resolve) => {
          const s = net.connect(port, '127.0.0.1');
          let got = '';
          s.on('connect', () => s.write(`GET /after?id=${id} HTTP/1.1\r\nHost: x\r\n\r\n`));
          s.on('data', (d) => {
            got += d;
            if (got.includes('done')) {
              if (how === 'rst') s.resetAndDestroy();
              else s.destroy();
              resolve();
            }
          });
          s.on('error', () => {});
        });
        await sleep(1300);
        r[`complete body, then the client goes away (${how})`] = await events(base, id);
      }
      // A long check: the write that hangs after the client went away, 5 s later.
      const id = 'long-rst';
      await rawClient(port, `/stream?id=${id}&n=50&gap=100`, 'rst');
      await sleep(5000);
      r['TCP reset, waitUntil, after 5 s'] = await events(base, id);
    }
    for (const w of ['0', '1']) {
      const id = `timer-${w}`;
      await fetch(`${base}/timer?id=${id}&wait=${w}`).then((x) => x.text());
      await sleep(400);
      r[`timer of 100 ms after the response, waitUntil=${w}`] = await events(base, id);
    }
    out[cfg] = r;
  });
}
console.log(JSON.stringify(out, null, 1));
