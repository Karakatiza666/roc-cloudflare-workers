// The shim (`js/index.js`) in Node. `js/index.js` imports `cloudflare:workers`, which only workerd and Wrangler
// resolve. This module registers a resolve hook that gives Node the stand-in `bench/cf-workers-stub.mjs`, then
// imports the shim. A static import of `js/index.js` would resolve before the hook exists, so a test imports this.
import { registerHooks } from 'node:module';

const stub = new URL('./cf-workers-stub.mjs', import.meta.url).href;
registerHooks({
  resolve(specifier, context, next) {
    if (specifier === 'cloudflare:workers') return { url: stub, shortCircuit: true };
    return next(specifier, context);
  },
});

export const { makeHandler } = await import('../js/index.js');
export const { WorkerEntrypoint } = await import('cloudflare:workers');
