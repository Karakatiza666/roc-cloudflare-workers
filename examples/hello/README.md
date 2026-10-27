# hello

A Worker with a Roc app. It shows the files of a project that uses a release of the platform.

| File | What it is |
| --- | --- |
| `main.roc` | The app. Its platform line is a path, so the repo can test it. In your project, write the release URL. `Worker.new({ ..., bindings: [db.declare()] })` puts the D1 binding in the manifest. |
| `worker.js` | The entry: `makeHandler(app)` from the shim. `node js/cli.mjs sync` wrote it. In this repo it imports `../../js/index.js` (the relative path to `js/`). In your project it imports `./.roc-cfw/index.js`. |
| `wrangler.toml` | The config, with the flags `enable_request_signal` and `global_fetch_strictly_public` (a `fetch` of another Worker of the same account on workers.dev gives 404 `error code: 1042` without it), and one D1 binding `DB`. |
| `.gitignore` | `.roc-cfw/` (the copy of `js/` in a project) and `*.wasm`. |
| `with_cbor.roc` | A second app: it adds the roc-cbor URL too. Only for the tests (`scripts/test_bundle.sh`). |

| Route | Answer |
| --- | --- |
| `/` | `hello from Roc` |
| `/d1` | A D1 row in a record: `Ok [{ avatar: [1, 2, 3], id: 1, name: "ann" }]` |
| `/cbor` | `Cbor.encode` then `Cbor.parse` of a record with a `Cbor.Bytes` field |
| `/fetch?url=U` | `status <n>` of `Http.get!(U)` |

## Build in the repo

The scripts are in the `talon.toml` of the repository root. Run them from the root.

| Command | What it does |
| --- | --- |
| `tln run hello` | `roc build --target=wasm32 --no-cache --output=examples/hello/app.wasm examples/hello/main.roc`, then `node ../../js/cli.mjs sync` in `examples/hello` (it writes `worker.js` and checks `wrangler.toml`) |
| `cd examples/hello && wrangler dev --local` | Run it. Then `curl http://127.0.0.1:8787/` |

## Use it in your project

There is no `package.json` and no npm package. The helper `roc-cfw` 0.0.1 writes this example from `js/template/` of the bundle (`main.roc` body, `wrangler.toml`, `.gitignore`, `[scripts]` in `talon.toml`) and copies `js/` of the bundle to `.roc-cfw/`.

| Step | Command |
| --- | --- |
| 1 | `tln init --platform Karakatiza666/roc-cloudflare-workers` |
| 2 | `tln add --tool Karakatiza666/roc-cloudflare-workers-cli --as roc-cfw` |
| 3 | `tln x roc-cfw -- init` |
| 4 | `tln run build`: `roc build`, then `roc-cfw sync` (it writes `worker.js` with `import ... from './.roc-cfw/index.js'` and checks `wrangler.toml`) |
| 5 | `wrangler dev --local`, then `curl http://127.0.0.1:8787/` |
| 6 | For `wrangler deploy`: `wrangler d1 create <name>` and put its id in `wrangler.toml` |

With platform 0.0.1, step 4 stops with exit 2 after the build (a warning in the platform). Then run `tln x roc-cfw -- sync`. The `README.md` of the repository root has the output of a real run, the gaps and the manual way with no helper.

## Test in the repo

`scripts/test_bundle.sh` (after `scripts/bundle.sh`) builds both apps against the bundle in `dist/`, copies `js/` of the unpacked bundle to `.roc-cfw/` of a copy of this project, runs `node .roc-cfw/cli.mjs sync` and `sync --check`, runs the project in `wrangler dev --local`, and runs `wrangler deploy --dry-run`. It deploys nothing.
