// `Version` (MODULES.md 13): routes of conformance/VersionRoutes.roc. `V` is the local version metadata of Miniflare (a
// random id, the tag "", the time of the start); `STUB_VERSION` is the stub of conformance/bindings.js with known values.
import { answer, eq, ok } from '../assert.mjs';

export const options = { versionMetadata: 'V' };

export const checks = [
  ['version metadata!: the local binding', async (t) => {
    const r = await t.get('/version/metadata?name=V');
    const m = /^([0-9a-f-]{36}) tag= ts=(\d+)$/.exec(r.body);
    ok(r.status === 200 && m, `got ${r.status} ${r.body}`);
    const age = Date.now() - Number(m[2]);
    ok(age >= 0 && age < 600_000, `the timestamp is ${age} ms old`);
    // One call!, no wait (the program has no promise).
    eq(r.awaits + r.calls, 1, 'crossings');
    eq(r.calls, 1, 'js_call');
    return `id ${m[1]}, ${age} ms old, 1 call!`;
  }],
  ['version metadata!: id, tag and timestamp of a known object', async (t) => {
    answer(await t.get('/version/metadata?name=STUB_VERSION'), `v-1 tag=rel ts=${Date.parse('2026-01-02T03:04:05.678Z')}`);
  }],
];
