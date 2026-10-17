// The entry of the Worker: the app (app.wasm, made by `roc build`) behind the shim.
// `import app from './app.wasm'` gives a WebAssembly.Module (Wrangler compiles it at build time).
import app from './app.wasm';
import { makeHandler } from 'roc-cloudflare-workers';

export default makeHandler(app);
