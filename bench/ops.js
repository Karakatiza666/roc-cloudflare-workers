// The ops of the bench apps (bench/app.roc `effect!`, app_deep.roc, app_stack.roc): the root `ops` of their programs
// (API.md 6.4). Each op calls `io(kind, a, b, context)` of a test, with the arguments of the old wait import
// (`Wait.wait!`, removed in PLAN.md 8a): kind 1 is a fetch (a: the method, b: the url), kind 2 a db query (a: the
// query). `context`: `{ env, ctx, event }`, the roots of the task that the program gives as the last arguments.
export const benchOps = (io) => ({
  fetch: (method, url, env, ctx, event) => io(1, method, url, { env, ctx, event }),
  db: (q, env, ctx, event) => io(2, q, '', { env, ctx, event }),
});
