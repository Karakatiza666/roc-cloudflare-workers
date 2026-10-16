// A stand-in for `cloudflare:workers` in Node (PLAN.md 8b). workerd gives the real module. `WorkerEntrypoint` takes
// `(ctx, env)` and keeps them as `this.ctx` and `this.env`, as in workerd.
export class WorkerEntrypoint {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
  }
}
