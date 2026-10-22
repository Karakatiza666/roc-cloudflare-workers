# auction (Gavel)

Two Workers and a Durable Object class over the platform. `REVIEW.md` is the ergonomics review of this code.

| File | What it is |
| --- | --- |
| `web.roc` | auction-web: the HTTP routes, KV, R2, D1. Its entry file is `worker.js`, its config is `wrangler-web.toml`. |
| `LotRoom.roc` | The Durable Object class `LotRoom` (live bids). It is in the script of auction-web. |
| `ledger.roc` | auction-ledger: settles closed lots and reads the FX feed. Its entry file is `worker-ledger.js`, its config is `wrangler-ledger.toml`. |
| `Gavel.roc` | The types, the interfaces (`Gavel.Room`, `Gavel.Ledger`: types with no values, one for each callee), the Rpc methods and the bindings that both Workers use. |

## Build

Run the commands from the root of the repository. The platform line of each app is a relative path (`../../platform/main.roc`): a build inside `examples/auction/` gives `PathOutsideWorkspace`.

```sh
roc build --target=wasm32 --no-cache --output=.cache/auction/web.wasm examples/auction/web.roc
roc build --target=wasm32 --no-cache --output=.cache/auction/ledger.wasm examples/auction/ledger.roc
roc test examples/auction/ledger.roc
```

A `roc build` with type errors still writes the `.wasm` file. It prints "N errors and 0 warnings found ... while successfully building" and exits with 1. The build is good only when the exit code is 0 and the text is "0 errors and 0 warnings". A script checks the exit code, not the file.

A one-field record is a block: write `{ name: name }`, not `{ name }` (`MODULES.md` 12.1).

## Deploy

| Step | Command |
| --- | --- |
| Write the entry files and check the config | `roc-cloudflare-workers sync` (needs the `.wasm` files next to the `worker*.js` files and the config files) |
| Run | `wrangler dev --config wrangler-web.toml` |
