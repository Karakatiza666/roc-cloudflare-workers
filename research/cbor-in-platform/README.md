# `Cbor` in the platform (PLAN.md 8c, 2026-10-16)

How the platform and an app get the module `Cbor` of the package `roc-cbor` 0.1.0 (nightly 2026-10-12).

| File | Shows | Result |
| --- | --- | --- |
| `own_dep.roc` | The app has its own `cbor` dependency, the same URL as the platform header, and `import cbor.Cbor` | Compiles. The types are the same: two modules with the same content are one type (`roc-syntax`, topic `packages`). |
| `reexport.roc` | The platform lists `Cbor` (a module of its package) in `exposes`, and the app imports `pf.Cbor` | Does not compile: `package module is private`. A platform cannot re-export a module of a package. |
| `app_no_cbor_call.roc` | `bench/platform`, no `cbor` entry. `rows : Try(List(Person), _)`, `rows = db.all!(sql, [])` | Compiles and builds (wasm32). The derived parser lives with the record type. |
| `app_no_cbor_infer.roc` | Same, plus a helper with no annotation: `read! = \|sql\| db.all!(sql, [])` | Compiles and builds. The compiler infers the `where` clause. |
| `app_no_cbor_infer_annot.roc` | Same helper with `Try(rows, _)` and no `where` | Does not compile: `missing method`, "A where clause requires the parser_for method here". |
| `app_no_cbor_where.roc` | Helper with `where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]`, no `cbor` entry | Does not compile: `module not imported`, "There is no module with the name Cbor imported into this Roc file." |
| `app_no_cbor_raw_where.roc` | Helper with a raw constraint: `where [rows.parser_for : _ -> (_ -> Try({ value : rows, rest : _ }, _))]` | Compiles and builds. Fragile: the text hides the real type of `parser_for`. |
| `app_no_cbor_bad_type.roc` | Negative control: a row type with a function field, no `cbor` entry | Does not compile: `missing method` (`parser_for`). So the probes above do check the derived parser. |
| `plat/` | A copy of `bench/platform/*.roc` (no `targets/`, so `roc check` and `roc test` work, `roc build` does not). `Codec.roc` is new, `main.roc` lists `Codec` in `exposes`. The `main_*.roc` files are the platform roots of the 4 probes below. | Not a probe. |
| `app_codec_basic.roc` | `plat/Codec.roc` wraps Cbor: aliases `Bytes`, `Parseable`, functions `parse`, `encode`, `bytes`. The app has no `cbor` entry, a `where [rows.Codec.Parseable(...)]` helper, a `Codec.Bytes` field, `Codec.parse`, `Codec.encode` | Compiles (and builds with `bench/platform/targets`). |
| `app_codec_custom.roc` | The app writes its own `parser_for` with `Codec.Format` and `Codec.State` (aliases of `Cbor`, `Cbor.State`) and calls `enc.parse_str(state)` by static dispatch. A round-trip `expect`. | Compiles, builds, `roc test` passes (the `expect` fails when the expected value is changed). |
| `app_named_cbor.roc` (`plat_named/Cbor.roc`, `plat_named/main.roc`) | The platform module is named `Cbor` and does `import cbor.Cbor as CborPkg`. The app does `import pf.Cbor` with no cbor entry, and writes `Cbor.Bytes`, `Cbor.Parseable`, `Cbor.parse`, `Cbor.encode` as with the package. | Compiles (`roc check`). Control `app_named_cbor_bad.roc` (`Cbor.bytes("x")`): type mismatch, so the check reads the wrapper. |
| `app_pf_and_pkg.roc` | The final platform (`bench/platform`, with `Cbor`): the app adds the package URL too and uses `pf.Cbor` and `import cbor.Cbor as CborPkg` together. A `pf.Cbor.Bytes` goes where a `CborPkg.Bytes` is wanted, in both directions of `parse` and `encode`. | Compiles. The types are the same. |
| `app_pf_expose_cbor.roc` | `plat/main_expose_cbor.roc`: `import cbor.Cbor` and `Cbor` in `exposes` | Does not compile: `package module is private`. |
| `app_pf_expose_as.roc` | `plat/main_expose_as.roc`: `exposes [Cbor as Codec2]` | Does not compile: `package module is private` (`pf.Codec2`). |
| `app_pf_expose_nested.roc` | `plat/main_expose_nested.roc`: `exposes [Cbor.Bytes]` | Does not compile: `package module is private` (`pf.Cbor`). |
| `app_pf_root_alias.roc` | `plat/main_root_alias.roc`: `Bytes : Cbor.Bytes` in the platform root, `Bytes` in `exposes` | Does not compile: `package module is private` (`pf.Bytes`). |

Run (from the repo root, with `bench/platform/main.roc` as it is, and for `reexport.roc` with `Cbor` added to its `exposes` and `import cbor.Cbor`):

```sh
ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache $ROC check research/cbor-in-platform/own_dep.roc
```

The download goes to `$XDG_CACHE_HOME/roc/packages/<hash>/` (with `<hash>.deps.json`).

Chosen (2026-10-16, PLAN.md DO1): the form of `app_named_cbor.roc`. `platform/Cbor.roc` and `bench/platform/Cbor.roc` are the module `Cbor` that wraps the package (`import cbor.Cbor as CborPkg`), and the apps have no `cbor` entry. `app_pf_and_pkg.roc` shows that an app that also adds the package URL gets the same types.

Rule in the compiler (`/home/george/dev/Karakatiza666/roc`, commit dd03c09e98): `src/compile/coordinator.zig:5374` (`scheduleExternalImport`) returns `.not_public` when the module is not in the public map of the target package. `src/compile/module_discovery.zig:57-134` (`extractPublicSurface`) builds that map from `exposes`. For a platform, an entry is a module only when a local import in the same file binds its name (`import Codec`, `origin == .local`). Any other entry (`Cbor` from `import cbor.Cbor`, `Cbor as X`, `Cbor.Bytes`, a type alias) is a root name, not a module.
