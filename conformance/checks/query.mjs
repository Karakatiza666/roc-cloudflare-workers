// `Request.query`, `query_all`, `query_pairs` (MODULES.md 4, "Query parameters"): routes of conformance/QueryRoutes.roc.
// The want of each input is `new URL(url).searchParams` of Node (application/x-www-form-urlencoded, WHATWG URL 5.1):
// the pairs, `getAll(name)` and `get(name)` for each name and for the name `__none__`.
import { canon } from '../canon.mjs';
import { ok } from '../assert.mjs';

export const options = {};

// The answer of the route as URLSearchParams gives it.
const want = (url) => {
  const sp = new URL(url).searchParams;
  const pairs = [...sp];
  const names = [...new Set(pairs.map(([k]) => k)), '__none__'];
  return { pairs, names: names.map((name) => ({ name, all: sp.getAll(name), first: sp.has(name) ? [sp.get(name)] : [] })) };
};

// Each query of `list` through `GET /query/parse?<query>` (Miniflare gives the worker the URL as Node writes it).
const viaGet = async (t, list) => {
  for (const q of list) {
    const r = await t.get(`/query/parse?${q}`);
    const w = canon(want(`http://localhost/query/parse?${q}`));
    ok(r.status === 200 && canon(JSON.parse(r.body)) === w, `?${q.slice(0, 80)}: got ${r.status} ${r.body.slice(0, 300)}, want ${w.slice(0, 300)}`);
  }
  return `${list.length} inputs`;
};

// Each URL of `list` through `POST /query/of` (the body is the URL: `Request.get(body)`).
const viaOf = async (t, list) => {
  for (const u of list) {
    const r = await t.get('/query/of', { method: 'POST', body: u });
    const w = canon(want(u));
    ok(r.status === 200 && canon(JSON.parse(r.body)) === w, `${JSON.stringify(u)}: got ${r.status} ${r.body.slice(0, 300)}, want ${w.slice(0, 300)}`);
  }
  return `${list.length} inputs`;
};

const fifty = Array.from({ length: 50 }, (_, i) => `short=v${i}`).join('&');

export const checks = [
  ['query separators: &, the first =, an empty name, an empty value, no =, ;, empty parts', (t) =>
    viaGet(t, ['a=1&a=2', '=x&y', 'a=&b', 'a', '&&a&&', 'a=b=c', '==', 'j=a;b=c', ';=;', '&=&', 'a=1&b=2&a=3'])],
  ['query decoding: + is a space, %2B is +, a bad % stays, UTF-8 escapes', (t) =>
    viaGet(t, ['a+b=c+d', 'a=%2B&b=%2b', 'a=%', 'a=%zz&b=%4&c=%%41', 'e=%C3%A9', 'k=%41%42', 'n=%00x', '%61=1', 'u=%F0%9F%98%80', 'raw=%C3%A9+%20x'])],
  ['query decoding: invalid UTF-8 is U+FFFD as URLSearchParams gives it', (t) =>
    viaGet(t, ['f=%FF', 'g=%E2%82', 'h=%E2%82A', 'i=%ED%A0%80', 'j=%F0%90%80', 'k=%C0%AF', 'l=%F4%90%80%80', 'm=%80%80', 'n=%E0%80%80', 'o=%F5x', 'p=%EF%BB%BFk', 'q=a%FFb%C3'])],
  ['query repeated: 50 values in order, a long value; query is the first of query_all', (t) =>
    viaGet(t, [fifty, `${fifty}&x=1&short=last`, `long=${'%C3%A9a+'.repeat(800)}&long=2`, `${'k'.repeat(3000)}=v`])],
  ['query of a URL that HTTP does not send: a fragment, # before ?, a tab, end spaces, no ?', (t) =>
    viaOf(t, ['https://x.dev/p?a=1#b=2', 'https://x.dev/p#x?a=1', 'https://x.dev/p?a=1?b=2', 'https://x.dev/p?a=1\tb=2\n', 'https://x.dev/p?a=1  ', 'https://x.dev/p', 'https://x.dev/p?', 'https://x.dev/p?#', 'https://x.dev?a=1', 'https://x.dev/p?a=1\r\n&b'])],
];
