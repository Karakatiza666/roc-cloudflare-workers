// The body the app must give for request `id` at recursion `depth`.
export function expected(id, depth = 50) {
  let sum = 0;
  for (let n = 1; n <= depth; n++) sum += n * 1000 + `level-${n}-of-request-${id}`.length + 1;
  return { sum, prefix: `id=${id} `, suffix: ` sum=${sum} fetch=f:${id} db=d:${id}` };
}

export function check(id, body, depth = 50) {
  const e = expected(id, depth);
  return body.startsWith(e.prefix) && body.endsWith(e.suffix);
}

// PLAN.md 8b: the bench apps get their request text as the body of a `Fetch` event (`bench/app.roc` `event!`), and
// answer it as the body of `Respond`. The URL is short (9 bytes), so it is a small string in Roc: no heap block.
const utf8 = new TextEncoder();
export function benchEvent(text) {
  return { kind: 'fetch', request: { method: 'POST', url: 'http://b/', headers: [], body: utf8.encode(text) } };
}

// The body of a `Respond` outcome as text. Another outcome: its JSON, so a check of the body fails.
const fromUtf8 = new TextDecoder();
export function benchBody(outcome) {
  if (outcome?.outcome !== 'respond') return `outcome ${JSON.stringify(outcome)}`;
  const b = outcome.body;
  return b === null || b === undefined ? '' : typeof b === 'string' ? b : fromUtf8.decode(b);
}
