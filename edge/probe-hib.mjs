// PLAN.md 8f part 3 on the edge: the real eviction of an object with an open hibernatable socket (no
// `unsafeEvictDurableObject`), and an auto response while the object is out of memory. The class `Room` of
// conformance/WebSocketRoutes.roc answers "info" with `user=<attachment> starts=<constructor runs> events=<socket events> ...`.
//   EDGE=https://rocplat-test-app.<sub>.workers.dev node edge/probe-hib.mjs [idle seconds, default 90]
const EDGE = process.env.EDGE.replace(/\/$/, '');
const IDLE = Number(process.argv[2] ?? 90) * 1000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const out = (o) => console.log(JSON.stringify(o));
const tag = Date.now().toString(36);

function room(name, user) {
  const ws = new WebSocket(`${EDGE.replace('https:', 'wss:')}/websocket/room/${name}?user=${user}`);
  const queue = [];
  let wake = null;
  ws.onmessage = (m) => { queue.push(String(m.data)); wake?.(); };
  const next = async () => { while (!queue.length) await new Promise((r) => { wake = r; }); return queue.shift(); };
  return new Promise((r, j) => { ws.onopen = () => r({ ws, next }); ws.onerror = () => j(new Error('ws failed')); });
}

const [hib, auto] = await Promise.all([room(`hib-${tag}`, 'a'), room(`auto-${tag}`, 'a')]);
hib.ws.send('info');
out({ hib: 'before', got: await hib.next() });
out({ auto: 'set', got: await (await fetch(`${EDGE}/websocket/room_admin/auto-${tag}?op=auto`)).text() });
auto.ws.send('info');
out({ auto: 'before', got: await auto.next() });
await sleep(IDLE);
auto.ws.send('ping');
out({ auto: `ping after ${IDLE / 1000} s`, got: await auto.next() });
auto.ws.send('info');
out({ auto: 'info after the ping', got: await auto.next() });
hib.ws.send('info');
out({ hib: `after ${IDLE / 1000} s idle`, got: await hib.next() });
hib.ws.close(1000, 'done');
auto.ws.close(1000, 'done');
await sleep(1000);
process.exit(0);
