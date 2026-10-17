# hello

A Worker with a Roc app. It shows the files of a project that uses a release of the platform.

| File | What it is |
| --- | --- |
| `app.roc` | The app. Its platform line is a path, so the repo can test it. In your project, write the release URL. |
| `worker.js` | The entry: `makeHandler(app)` from the shim package. |
| `wrangler.toml` | The config, with the flags `enable_request_signal` and `global_fetch_strictly_public` (a `fetch` of another Worker of the same account on workers.dev gives 404 `error code: 1042` without it), and one D1 binding `DB`. |
| `package.json` | The shim package by release URL, and the scripts `build`, `dev`, `deploy`. |
| `with_cbor.roc` | A second app: it adds the roc-cbor URL too. Only for the tests (`scripts/test_bundle.sh`). |

| Route | Answer |
| --- | --- |
| `/` | `hello from Roc` |
| `/d1` | A D1 row in a record: `Ok [{ avatar: [1, 2, 3], id: 1, name: "ann" }]` |
| `/cbor` | `Cbor.encode` then `Cbor.parse` of a record with a `Cbor.Bytes` field |
| `/fetch?url=U` | `status <n>` of `Http.get!(U)` |

## Use it in your project

1. Copy this directory. In `app.roc`, change the platform line to the URL of a release.
2. In `package.json`, change `X.Y.Z` in the URL of `roc-cloudflare-workers` to the same release. Run `npm install`.
3. `npm run build` (`roc build --target=wasm32 --no-cache --output=app.wasm app.roc`).
4. `npm run dev` (`wrangler dev --local`), then `curl http://127.0.0.1:8787/`.
5. For `npm run deploy`: `wrangler d1 create roc-hello` and put its id in `wrangler.toml`.

## Test in the repo

`scripts/test_bundle.sh` (after `scripts/bundle.sh`) builds both apps against the bundle in `dist/`, runs this project in `wrangler dev --local` with the shim package of `dist/`, and runs `wrangler deploy --dry-run`. It deploys nothing.
