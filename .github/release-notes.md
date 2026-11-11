## Use the platform

In the header of your app (a Roc nightly is needed: @NIGHTLY@):

```roc
app [event!] { pf: platform "@URL@" }
```

The bundle has the JS shim in `js/` (`makeHandler`, `objectClass`, `entrypointClass`, and `cli.mjs` with the command `sync`).
There is no npm package. With Talon (`tln`), a new project (the README steps; `init` takes the newest release that is old enough):

```sh
tln init --platform Karakatiza666/roc-cloudflare-workers
```

An existing project, to this release:

```sh
tln add --platform Karakatiza666/roc-cloudflare-workers@@TAG@
```

The helper `roc-cfw` (`tln add --tool Karakatiza666/roc-cloudflare-workers-cli --as roc-cfw`) copies `js/` to `.roc-cfw/`
of your project and runs `sync`. With no helper, copy `js/` of the bundle to `.roc-cfw/` and run `node .roc-cfw/cli.mjs sync`.
`sync` writes the `worker.js` that imports `./.roc-cfw/index.js`.

Then `roc build --target=wasm32 --no-cache --output=app.wasm main.roc`.
The compatibility flag `enable_request_signal` is required in the Wrangler config. The README has the full steps.

## No `cbor` entry in the app header

The platform has its own module `Cbor`: `import pf.Cbor`. It wraps roc-cbor 0.5.0, which the platform
header takes by URL. An app needs no `cbor` entry and no `http` entry.

An app may add the same roc-cbor URL. The types are the same: a `Cbor.Bytes` of `pf.Cbor` goes where a `Bytes`
of the package is wanted. If the app adds another version of roc-cbor, its types are other types.

## Stored data: read before the deploy

0.0.10 changes the CBOR format of stored data (roc-cbor 0.2.3 to 0.5.0, strict reads). Before the deploy, read
`README.md` "Changes in 0.0.10" and `MODULES.md` 1 "Migration of stored data". Run `Object.Cell.migrate!` and
`Object.Attachment.migrate!` once after the deploy.

## Known gaps

The full list is in `README.md` "Known gaps".

- Not possible (they need calls from JS into Roc): a Workflow written in Roc, `HTMLRewriter`, `blockConcurrencyWhile` in a handler and `transactionSync`.
- Not built: Workflows `restart`, `createBatch`, instance `delete` and `subscribe`; `Ai` binary output and an SSE parser; `Response.from_http` and `to_http!`; a Hyperdrive SQL driver; the `TraceItem` fields `cpuTime`, `wallTime` and others.
- No module: Images, Browser Rendering, mTLS, dispatch namespaces, Containers, Pipelines. Use a `Js` program.
- KV-backed Durable Object classes are refused. Use SQLite-backed classes.
- A queue body that CBOR cannot write is retried with an empty body. The handler does not see it.
- Not tested on the edge (only local results): `Tcp` StartTls, Ed25519, X25519, P-521, `location_hint`, `can_be_forwarded`, `web_socket_error!`, the socket limits, `binaryType`. `Ai` and `Vectorize` results are tested with stubs only.

## Files

| File | What it is |
| --- | --- |
| `@BUNDLE_NAME@` | The platform bundle: the Roc modules, `LICENSE`, the production host `targets/wasm32/host.wasm`, and the shim in `js/`. The packages `http` and `cbor` stay URLs. The shim and the host are in one file, so they have the same version. |

Built with Roc `@NIGHTLY@` and Zig 0.17.0.

Breaking changes for app authors: the section "Changes in <version>" of `README.md` at the tag.
