// The kind check of js/bindings.js on the local bindings of wrangler dev (step 8h wave B, issue 5). GET / gives, for each
// binding of wrangler.toml, the problems of its own kind (want: none) and the other kinds that it passes too.
import { WorkerEntrypoint, WorkflowEntrypoint, DurableObject } from 'cloudflare:workers';
import { BINDING_KINDS, bindingProblems } from '../../../js/bindings.js';

export class Thing extends DurableObject {}
export class Flow extends WorkflowEntrypoint {
  async run() {}
}
const BINDINGS = { DB: 'd1', KV: 'kv', BUCKET: 'r2', THINGS: 'object', SELF: 'service', JOBS: 'queue', MAIL: 'email', FLOW: 'workflows', ASSETS: 'assets', HD: 'hyperdrive', RL: 'ratelimit', VERSION: 'version', ANALYTICS: 'analytics' };

export default class extends WorkerEntrypoint {
  async fetch() {
    const out = {};
    for (const [name, kind] of Object.entries(BINDINGS)) {
      const own = bindingProblems([{ name, kind }], this.env);
      const also = Object.keys(BINDING_KINDS).filter((k) => k !== kind && bindingProblems([{ name, kind: k }], this.env).length === 0);
      out[name] = { kind, own: own.length ? own : 'ok', alsoPasses: also };
    }
    return Response.json(out);
  }
}
