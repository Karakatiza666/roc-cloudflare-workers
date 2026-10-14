// node q123.mjs <port>: the client drops each request 300 ms after it starts, then reads the log.
const B = 'http://127.0.0.1:' + process.argv[2];
const cases = [];
for (const mode of ['js', 'shared', 'fresh']) for (const kind of ['timer', 'fetch']) cases.push({ mode, kind, id: `${mode}-${kind}` });
const t0 = Date.now();
await Promise.all(cases.map(async (c) => {
  const ac = new AbortController();
  setTimeout(() => ac.abort(), 300);
  try { await fetch(`${B}/wait?id=${c.id}&kind=${c.kind}&mode=${c.mode}&ms=3000&tm=2000`, { signal: ac.signal }); console.log(c.id, 'answered'); }
  catch { /* dropped by the client */ }
}));
await new Promise((r) => setTimeout(r, 8000));
const l = await (await fetch(B + '/log')).json();
const sl = await (await fetch(B + '/slowlog')).json();
const start = Object.fromEntries(l.log.filter((e) => e.what === 'start').map((e) => [e.id, e.t]));
for (const c of cases) console.log(c.id.padEnd(14), l.log.filter((e) => e.id === c.id).map((e) => `${e.what}@${e.t - start[c.id]}${e.err ? '(' + e.err.slice(0, 60) + ')' : ''}`).join(' '));
for (const e of sl) console.log('slow', e.id, e.what, e.t - (start[e.id] ?? e.t));
