// node show.mjs <port> <id-prefix>: the events of each id, in ms after its start.
const B = 'http://127.0.0.1:' + process.argv[2], pre = process.argv[3];
const l = (await (await fetch(B + '/log')).json()).log.filter((e) => e.id.startsWith(pre));
const s = {}, by = {};
for (const e of l) if (e.what === 'start') s[e.id] = e.t;
for (const e of l) (by[e.id] ??= []).push(`${e.what}@${e.t - s[e.id.split(':')[0]]}${e.err ? '(' + e.err.slice(0, 80) + ')' : ''}`);
for (const k of Object.keys(by).sort()) console.log(k.padEnd(22), by[k].join(' '));
