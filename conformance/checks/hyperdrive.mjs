// `Hyperdrive.config!` (MODULES.md 13): routes of conformance/HyperdriveRoutes.roc, on the local Hyperdrive of Miniflare
// (it gives a host name of its own, `<hash>.hyperdrive.local`, and `?sslmode=disable` in the connection string).
import { eq, ok } from '../assert.mjs';

export const options = { hyperdrives: { PG: 'postgres://user:secret@localhost:5432/mydb' } };

export const checks = [
  ['hyperdrive config!: the six fields, the two secrets hidden, one call!', async (t) => {
    const r = await t.get('/hyperdrive/config?name=PG');
    const m = /^host=([0-9a-f]+\.hyperdrive\.local) port=5432 user=user database=mydb inspect=\{ cs: Secret\(\.\.\.\), pw: Secret\(\.\.\.\) \} password=secret cs=postgres:\/\/user:secret@([0-9a-f]+\.hyperdrive\.local):5432\/mydb\?sslmode=disable$/.exec(r.body);
    ok(r.status === 200 && m, `got ${r.status} ${r.body}`);
    eq(m[2], m[1], 'the host of the connection string');
    eq(r.awaits, 0, 'js_await');
    eq(r.calls, 1, 'js_call');
    return `host ${m[1]}`;
  }],
];
