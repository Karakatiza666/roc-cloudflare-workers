// PLAN.md 11c: the echo Worker of the edge run (`rocplat-test-echo`), the same routes as the local server of
// conformance/run.mjs: `/hello` (text), `/ten` (10 bytes), `/slow` (answers after 2 s), `/echo` (the method, the header
// `x-test` and the body), `/status/<n>` (that status, no body). Also `/hang` (answers after 10 min, a host that does not answer).
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export default {
  async fetch(req) {
    const path = new URL(req.url).pathname;
    if (path === '/hello') return new Response('hello');
    if (path === '/ten') return new Response('0123456789');
    if (path === '/slow') return sleep(2000).then(() => new Response('late'));
    if (path === '/hang') return sleep(600_000).then(() => new Response('late'));
    if (path === '/echo') return new Response(`${req.method} ${req.headers.get('x-test') ?? '-'} ${await req.text()}`);
    if (path.startsWith('/status/')) return new Response(null, { status: Number(path.slice(8)) });
    return new Response('no route', { status: 404 });
  },
};
