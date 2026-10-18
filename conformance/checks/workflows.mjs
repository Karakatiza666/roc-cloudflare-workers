// `Workflows`, the client (MODULES.md 13): routes of conformance/WorkflowsRoutes.roc on the local Workflows binding of
// Miniflare: `FLOW` (ends at once, gives its parameters and id) and `WAIT` (waits for the event `go`), the classes of
// conformance/bindings.js. `STUB_WORKFLOW` is a stub that records the calls.
import { answer, eq, ok } from '../assert.mjs';
import { canon } from '../canon.mjs';

export const options = {
  workflows: { FLOW: { name: 'flow', className: 'Flow' }, WAIT: { name: 'waiter', className: 'Waiter' } },
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const calls = async (t) => JSON.parse((await t.get('/__stub_calls')).body);
// The id of an instance made with no id. Local form: a UUID. Edge form (`t.edge`, PLAN.md 11c, E42): `cf_` and 64 hex digits.
const newId = (t) => (t.edge ? 'cf_[0-9a-f]{64}' : '[0-9a-f-]{36}');

// The status of an instance, until its state is `want` (the local engine runs the workflow in the background).
const until = async (t, path, want) => {
  let last;
  for (let i = 0; i < 40; i++) {
    last = await t.get(path);
    if (last.body.startsWith(`state=${want} `)) return last.body;
    await sleep(100);
  }
  throw new Error(`the state is not ${want}: ${last.body}`);
};

export const checks = [
  ['workflows create!, create (Io twin): an instance with a new id, and its output has the parameters', async (t) => {
    for (const p of ['create', 'create_io']) {
      const r = await t.get(`/workflows/${p}?binding=FLOW&pname=x&n=3`);
      const m = new RegExp(`^Ok id=(${newId(t)})$`).exec(r.body);
      ok(r.status === 200 && m, `${p}: got ${r.status} ${r.body}`);
      eq(r.awaits, 1, 'js_await');
      const s = await until(t, `/workflows/status?binding=FLOW&id=${m[1]}`, 'Complete');
      eq(s.endsWith(`done payload=x/3 id=${m[1]}`), true, `${p}: the typed output of ${s}`);
    }
  }],
  ['workflows create_with!, create_with (Io twin): the id of the app; the same id is AlreadyExists', async (t) => {
    answer(await t.get('/workflows/create_with?binding=FLOW&id=my-1&pname=y&n=4'), 'Ok id=my-1');
    answer(await t.get('/workflows/create_with?binding=FLOW&id=my-1&pname=y&n=4'), 'AlreadyExists');
    answer(await t.get('/workflows/create_with_io?binding=FLOW&id=my-2&pname=z&n=5'), 'Ok id=my-2');
    answer(await t.get('/workflows/create_with_io?binding=FLOW&id=my-2&pname=z&n=5'), 'AlreadyExists');
    const s = await until(t, '/workflows/status?binding=FLOW&id=my-1', 'Complete');
    eq(s.endsWith('done payload=y/4 id=my-1'), true, s);
    // No `id` field: a new id.
    ok(new RegExp(`^Ok id=${newId(t)}$`).test((await t.get('/workflows/create_with_none?binding=FLOW&pname=x&n=1')).body), 'create_with with no id');
  }],
  ['workflows get!, get (Io twin): the instance of an id, or NotFound', async (t) => {
    answer(await t.get('/workflows/get?binding=FLOW&id=my-1'), 'Ok id=my-1');
    answer(await t.get('/workflows/get_io?binding=FLOW&id=my-1'), 'Ok id=my-1');
    answer(await t.get('/workflows/get?binding=FLOW&id=nope'), 'NotFound');
    answer(await t.get('/workflows/get_io?binding=FLOW&id=nope'), 'NotFound');
  }],
  ['workflows status!, status (Io twin): the state, no error, the output as JSON text and typed', async (t) => {
    for (const p of ['status', 'status_io']) {
      const r = await t.get(`/workflows/${p}?binding=FLOW&id=my-1`);
      answer(r, 'state=Complete error=Err(NotSet) json=Ok("{\\"payload\\":{\\"n\\":4,\\"name\\":\\"y\\"},\\"id\\":\\"my-1\\"}") done payload=y/4 id=my-1');
      eq(r.awaits, 2, `${p}: get! and status!`);
    }
    answer(await t.get('/workflows/status?binding=FLOW&id=nope'), 'get: NotFound');
  }],
  ['workflows pause!, resume!, send_event!: a waiting instance, then its output has the event', async (t) => {
    answer(await t.get('/workflows/create_with?binding=WAIT&id=w1&pname=a&n=1'), 'Ok id=w1');
    await until(t, '/workflows/status?binding=WAIT&id=w1', 'Running');
    answer(await t.get('/workflows/pause?binding=WAIT&id=w1'), 'Ok');
    await until(t, '/workflows/status?binding=WAIT&id=w1', 'Paused');
    answer(await t.get('/workflows/resume?binding=WAIT&id=w1'), 'Ok');
    await until(t, '/workflows/status?binding=WAIT&id=w1', 'Running');
    answer(await t.get('/workflows/send_event?binding=WAIT&id=w1&n=7'), 'Ok');
    const s = await until(t, '/workflows/status?binding=WAIT&id=w1', 'Complete');
    eq(s.endsWith('waited started=a/1 got=7'), true, s);
  }],
  ['workflows pause (Io twin), resume (Io twin), send_event (Io twin)', async (t) => {
    answer(await t.get('/workflows/create_with?binding=WAIT&id=w2&pname=b&n=2'), 'Ok id=w2');
    await until(t, '/workflows/status?binding=WAIT&id=w2', 'Running');
    answer(await t.get('/workflows/pause_io?binding=WAIT&id=w2'), 'Ok');
    await until(t, '/workflows/status_io?binding=WAIT&id=w2', 'Paused');
    answer(await t.get('/workflows/resume_io?binding=WAIT&id=w2'), 'Ok');
    await until(t, '/workflows/status_io?binding=WAIT&id=w2', 'Running');
    answer(await t.get('/workflows/send_event_io?binding=WAIT&id=w2&n=9'), 'Ok');
    const s = await until(t, '/workflows/status_io?binding=WAIT&id=w2', 'Complete');
    eq(s.endsWith('waited started=b/2 got=9'), true, s);
  }],
  ['workflows terminate!, terminate (Io twin): a waiting instance ends; a finished one is WorkflowsErr', async (t) => {
    answer(await t.get('/workflows/create_with?binding=WAIT&id=w3&pname=c&n=3'), 'Ok id=w3');
    answer(await t.get('/workflows/create_with?binding=WAIT&id=w4&pname=d&n=4'), 'Ok id=w4');
    await until(t, '/workflows/status?binding=WAIT&id=w3', 'Running');
    answer(await t.get('/workflows/terminate?binding=WAIT&id=w3'), 'Ok');
    answer(await t.get('/workflows/terminate_io?binding=WAIT&id=w4'), 'Ok');
    await until(t, '/workflows/status?binding=WAIT&id=w3', 'Terminated');
    await until(t, '/workflows/status?binding=WAIT&id=w4', 'Terminated');
    const r = await t.get('/workflows/terminate?binding=FLOW&id=my-1');
    ok(r.status === 200 && r.body.startsWith('WorkflowsErr Error: ') && r.body.includes('instance.cannot_terminate'), `got ${r.status} ${r.body}`);
  }],
  ['workflows create!: the parameters (JSON) and the id reach the binding; with no id, no id is sent', async (t) => {
    await t.get('/__stub_reset');
    answer(await t.get('/workflows/create?binding=STUB_WORKFLOW&pname=x&n=5'), 'Ok id=generated');
    answer(await t.get('/workflows/create_with?binding=STUB_WORKFLOW&id=s1&pname=y&n=6'), 'Ok id=s1');
    const c = (await calls(t)).filter((x) => x.method === 'create');
    eq(canon(c.map((x) => x.args)), canon([[{ params: { name: 'x', n: 5 } }], [{ id: 's1', params: { name: 'y', n: 6 } }]]));
  }],
  ['workflows send_event!: the type and the payload (JSON) reach the binding', async (t) => {
    await t.get('/__stub_reset');
    answer(await t.get('/workflows/send_event?binding=STUB_WORKFLOW&id=s2&n=8'), 'Ok');
    const c = (await calls(t)).filter((x) => x.method === 'sendEvent');
    eq(canon(c.map((x) => x.args)), canon([['s2', { type: 'go', payload: { x: 8 } }]]));
  }],
  ['workflows: an instance that is gone is NotFound for each function', async (t) => {
    for (const f of ['status', 'pause', 'resume', 'terminate', 'send_event']) {
      await t.get('/__stub_reset');
      const want = f === 'status' ? 'status: NotFound' : 'NotFound';
      answer(await t.get(`/workflows/${f}?binding=STUB_WORKFLOW&id=vanishes`), want);
    }
  }],
  ['workflows: the stub gets the call that the function names', async (t) => {
    // `get` first, then the method (one program, any task can use the instance).
    for (const [f, m] of [['status', 'status'], ['pause', 'pause'], ['resume', 'resume'], ['terminate', 'terminate'], ['send_event', 'sendEvent']]) {
      await t.get('/__stub_reset');
      await t.get(`/workflows/${f}?binding=STUB_WORKFLOW&id=s3`);
      const names = (await calls(t)).map((x) => x.method);
      eq(canon(names), canon(['get', 'get', m]), f);
    }
  }],
  ['workflows F64 params and payload: a value is sent as JSON, a NaN is BadData and no call is made', async (t) => {
    await t.get('/__stub_reset');
    answer(await t.get('/workflows/create_f64?binding=STUB_WORKFLOW&n=0'), 'Ok id=generated');
    eq(canon((await calls(t)).filter((x) => x.method === 'create').map((x) => x.args)), canon([[{ params: { x: 0.5 } }]]), 'create');
    await t.get('/__stub_reset');
    for (const p of ['create_f64', 'create_f64_io']) {
      const r = await t.get(`/workflows/${p}?binding=STUB_WORKFLOW&n=1&id=nan1`);
      ok(r.status === 200 && r.body.startsWith('BadData the params do not encode: '), `${p}: ${r.body}`);
      eq(r.awaits, 0, `${p}: no crossing`);
    }
    eq((await calls(t)).length, 0, 'no call after a NaN in create');
    answer(await t.get('/workflows/send_event_f64?binding=STUB_WORKFLOW&id=s9&n=0'), 'Ok');
    eq(canon((await calls(t)).filter((x) => x.method === 'sendEvent').map((x) => x.args)), canon([['s9', { type: 'go', payload: { x: 0.5 } }]]), 'send_event');
    await t.get('/__stub_reset');
    const r = await t.get('/workflows/send_event_f64?binding=STUB_WORKFLOW&id=s9&n=1');
    ok(r.status === 200 && r.body.startsWith('BadData the payload does not encode: '), `send_event NaN: ${r.body}`);
    eq((await calls(t)).filter((x) => x.method === 'sendEvent').length, 0, 'no sendEvent call');
  }],
];
