// The echo service binding: /f answers after 5 ms, /d (the "db") after 1 ms.
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export default {
  async fetch(req) {
    const u = new URL(req.url);
    if (u.pathname === '/f') {
      await sleep(5);
      return new Response('f:' + u.searchParams.get('id'));
    }
    await sleep(1);
    return new Response('d:' + (u.searchParams.get('q') || '').split(' ')[1]);
  },
};
