## Use the platform

In the header of your app (a Roc nightly is needed: @NIGHTLY@):

```roc
app [event!] { pf: platform "@URL@" }
```

The JS shim is the file @SHIM_NAME@ of this release:

```sh
npm install @SHIM_URL@
```

Then `roc build --target=wasm32 --output=app.wasm app.roc`, and a `worker.js` with
`import app from './app.wasm'; import { makeHandler } from 'roc-cloudflare-workers'; export default makeHandler(app);`.
The compatibility flag `enable_request_signal` is required in the Wrangler config. The README has the full steps.

## No `cbor` entry in the app header

The platform has its own module `Cbor`: `import pf.Cbor`. It wraps roc-cbor 0.2.1, which the platform
header takes by URL. An app needs no `cbor` entry and no `http` entry.

An app may add the same roc-cbor URL. The types are the same: a `Cbor.Bytes` of `pf.Cbor` goes where a `Bytes`
of the package is wanted. If the app adds another version of roc-cbor, its types are other types.

## Files

| File | What it is |
| --- | --- |
| `@BUNDLE_NAME@` | The platform bundle: the Roc modules, `LICENSE`, and the production host `targets/wasm32/host.wasm`. The packages `http` and `cbor` stay URLs. |
| `@SHIM_NAME@` | The `roc-cloudflare-workers` package: `makeHandler`, `objectClass`, `entrypointClass`. It must have the same version as the platform bundle. |

Built with Roc `@NIGHTLY@` and Zig 0.17.0.
