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

There is no `package.json` and no npm package. The shim is a copy of `js/` of the platform bundle in `.roc-cfw/`.

1. Copy `main.roc`, `wrangler.toml` and `.gitignore` of this directory (the helper `roc-cfw init`, not released yet, will do this from `js/template/` of the bundle). In `main.roc`, write the release URL in the platform line.
2. Run `roc check main.roc`. Roc puts the bundle in its package cache. Copy `js/` of the bundle to `.roc-cfw/`: `cp -r ~/.cache/roc/packages/<hash>/js .roc-cfw` (`<hash>` is the file name in the URL, without `.tar.zst`).
3. `roc build --target=wasm32 --no-cache --output=app.wasm main.roc`, then `node .roc-cfw/cli.mjs sync`: it writes `worker.js` (with `import ... from './.roc-cfw/index.js'`) and checks `wrangler.toml`.
4. `wrangler dev --local`, then `curl http://127.0.0.1:8787/`.
5. For `wrangler deploy`: `wrangler d1 create roc-hello` and put its id in `wrangler.toml`.

The planned setup with the helper `roc-cfw` and `talon.toml` scripts (`tln run build`, `tln run dev`) is in the `README.md` of the repository root. The helper has no release yet.

## Test in the repo

`scripts/test_bundle.sh` (after `scripts/bundle.sh`) builds both apps against the bundle in `dist/`, copies `js/` of the unpacked bundle to `.roc-cfw/` of a copy of this project, runs `node .roc-cfw/cli.mjs sync` and `sync --check`, runs the project in `wrangler dev --local`, and runs `wrangler deploy --dry-run`. It deploys nothing.
