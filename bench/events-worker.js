// The app service of bench/config-entry.capnp (PLAN.md 8b): bench/app_events.wasm behind `makeHandler`. The default
// export is a subclass of the class of `makeHandler` (a `WorkerEntrypoint`), with one more path: `GET /__log` gives the
// log lines of the shim since the last read.
import app from 'app_events.wasm';
import { makeHandler } from './js/index.js';

const lines = [];
const Handler = makeHandler(app, {
  other: ['ping'],
  log: (text) => {
    lines.push(text);
    console.warn(text);
  },
});

export default class extends Handler {
  async fetch(request) {
    if (new URL(request.url).pathname === '/__log') return Response.json(lines.splice(0));
    return super.fetch(request);
  }
}
