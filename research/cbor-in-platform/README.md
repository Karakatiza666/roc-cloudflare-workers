# `Cbor` in the platform (PLAN.md 8c, 2026-10-16)

How the platform and an app get the module `Cbor` of the package `roc-cbor` 0.1.0 (nightly 2026-10-12).

| File | Shows | Result |
| --- | --- | --- |
| `own_dep.roc` | The app has its own `cbor` dependency, the same URL as the platform header, and `import cbor.Cbor` | Compiles. The types are the same: two modules with the same content are one type (`roc-syntax`, topic `packages`). |
| `reexport.roc` | The platform lists `Cbor` (a module of its package) in `exposes`, and the app imports `pf.Cbor` | Does not compile: `package module is private`. A platform cannot re-export a module of a package. |

Run (from the repo root, with `bench/platform/main.roc` as it is, and for `reexport.roc` with `Cbor` added to its `exposes` and `import cbor.Cbor`):

```sh
ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache $ROC check research/cbor-in-platform/own_dep.roc
```

The download goes to `$XDG_CACHE_HOME/roc/packages/<hash>/` (with `<hash>.deps.json`).
