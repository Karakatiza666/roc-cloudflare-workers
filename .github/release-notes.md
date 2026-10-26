## Use the platform

In the header of your app (a Roc nightly is needed: @NIGHTLY@):

```roc
app [event!] { pf: platform "@URL@" }
```

The bundle has the JS shim in `js/` (`makeHandler`, `objectClass`, `entrypointClass`, and `cli.mjs` with the command `sync`).
There is no npm package. With Talon (`tln`):

```sh
tln add --platform Karakatiza666/roc-cloudflare-workers@@TAG@
```

The helper `roc-cfw` copies `js/` to `.roc-cfw/` of your project and runs `sync` (planned: it has no release yet).
Until it has one, copy `js/` of the bundle to `.roc-cfw/` by hand and run `node .roc-cfw/cli.mjs sync`.
`sync` writes the `worker.js` that imports `./.roc-cfw/index.js`.

Then `roc build --target=wasm32 --no-cache --output=app.wasm main.roc`.
The compatibility flag `enable_request_signal` is required in the Wrangler config. The README has the full steps.

## No `cbor` entry in the app header

The platform has its own module `Cbor`: `import pf.Cbor`. It wraps roc-cbor 0.2.1, which the platform
header takes by URL. An app needs no `cbor` entry and no `http` entry.

An app may add the same roc-cbor URL. The types are the same: a `Cbor.Bytes` of `pf.Cbor` goes where a `Bytes`
of the package is wanted. If the app adds another version of roc-cbor, its types are other types.

## Files

| File | What it is |
| --- | --- |
| `@BUNDLE_NAME@` | The platform bundle: the Roc modules, `LICENSE`, the production host `targets/wasm32/host.wasm`, and the shim in `js/`. The packages `http` and `cbor` stay URLs. The shim and the host are in one file, so they have the same version. |

Built with Roc `@NIGHTLY@` and Zig 0.17.0.
