// The worker of bench/config-stream.capnp (PLAN.md 8b second half, 9c, 10a, 10b): bench/app_stream.wasm behind
// `makeHandler`, with the ops of bench/app_stream.roc. More paths: `GET /__log` (the log lines of the shim since the
// last read), `GET /__marks` (the marks of the app), `GET /__stats` (wasm memory and the task table).
import app from 'app_stream.wasm';
import { makeHandler } from './js/index.js';

const lines = [];
const marks = {};
const puts = {};
const ops = {
  // A wait of `ms` that stops with an AbortError when the signal aborts (OP8).
  sleep: (ms, signal) =>
    new Promise((resolve, reject) => {
      const onAbort = () => {
        clearTimeout(timer);
        reject(signal.reason);
      };
      const timer = setTimeout(() => {
        signal?.removeEventListener('abort', onAbort);
        resolve(ms);
      }, ms);
      if (signal?.aborted) onAbort();
      else signal?.addEventListener('abort', onAbort, { once: true });
    }),
  mark: (id, text) => {
    (marks[id] ??= []).push(text);
  },
  // A stand-in for a `Cache.named` put: it reads the stream to its end.
  put: async (key, stream) => {
    puts[key] = (await new Response(stream).arrayBuffer()).byteLength;
  },
  boom: () => {
    throw new TypeError('boom of the test');
  },
  one: () => 1,
};
const Handler = makeHandler(app, {
  ops,
  heapCheckWhenIdle: false,
  log: (text) => {
    lines.push(text);
    console.warn(text);
  },
});

export default class extends Handler {
  async fetch(request) {
    const path = new URL(request.url).pathname;
    if (path === '/__log') return Response.json(lines.splice(0));
    if (path === '/__marks') return Response.json({ marks, puts });
    if (path === '/__stats') {
      const r = Handler.runner;
      const s = r.tasks.stats;
      return Response.json({ mem: r.x.memory.buffer.byteLength, live: r.x.live_bytes(), tasks: r.tasks.size, byReason: s.byReason, refsLive: s.refsLive, contextsLive: s.contextsLive, alarms: r.stats.alarms });
    }
    return super.fetch(request);
  }
}
