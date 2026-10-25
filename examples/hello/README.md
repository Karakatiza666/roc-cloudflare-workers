# hello

A Worker with a Roc app. It shows the files of a project that uses a release of the platform.

| File | What it is |
| --- | --- |
| `main.roc` | The app. Its platform line is a path, so the repo can test it. In your project, write the release URL. `Worker.new({ ..., bindings: [db.declare()] })` puts the D1 binding in the manifest. |
| `worker.js` | The entry: `makeHandler(app)` from the shim package. `roc-cloudflare-workers sync` wrote it. |
| `wrangler.toml` | The config, with the flags `enable_request_signal` and `global_fetch_strictly_public` (a `fetch` of another Worker of the same account on workers.dev gives 404 `error code: 1042` without it), and one D1 binding `DB`. |
| `package.json` | The shim package by release URL, and the scripts `build` (`roc build`, then `roc-cloudflare-workers sync`), `sync`, `dev`, `deploy`. |
| `with_cbor.roc` | A second app: it adds the roc-cbor URL too. Only for the tests (`scripts/test_bundle.sh`). |

| Route | Answer |
| --- | --- |
| `/` | `hello from Roc` |
| `/d1` | A D1 row in a record: `Ok [{ avatar: [1, 2, 3], id: 1, name: "ann" }]` |
| `/cbor` | `Cbor.encode` then `Cbor.parse` of a record with a `Cbor.Bytes` field |
| `/fetch?url=U` | `status <n>` of `Http.get!(U)` |

## Use it in your project

1. Copy this directory (`roc-cloudflare-workers init` moved to the helper `roc-cfw init`, not released yet), change the platform line of `main.roc` and `X.Y.Z` in `package.json` by hand.
2. Run `npm install`.
3. `npm run build` (`roc build --target=wasm32 --no-cache --output=app.wasm main.roc`, then `roc-cloudflare-workers sync`: it writes `worker.js` and checks `wrangler.toml`).
4. `npm run dev` (`wrangler dev --local`), then `curl http://127.0.0.1:8787/`.
5. For `npm run deploy`: `wrangler d1 create roc-hello` and put its id in `wrangler.toml`.

## Test in the repo

`scripts/test_bundle.sh` (after `scripts/bundle.sh`) builds both apps against the bundle in `dist/`, runs `roc-cloudflare-workers sync --check` and this project in `wrangler dev --local` with the shim package of `dist/`, and runs `wrangler deploy --dry-run`. It deploys nothing.
