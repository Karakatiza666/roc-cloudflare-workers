# cloudflare-workers

A Roc platform for Cloudflare Workers. The app compiles to a wasm32 reactor. The host is in Zig. Effects (fetch, D1, R2, KV, Cache API, Durable Object SQL) are direct-style hosted functions that wait on JS promises through JSPI.

Status: design and benchmarks. The app API is in `API.md`, the host work in `PLAN.md`, the measurements in `bench/` and `research/`.

The JS shim is in `js/`. Its entry is `js/index.js`, which exports `makeHandler(module, opts)`.
