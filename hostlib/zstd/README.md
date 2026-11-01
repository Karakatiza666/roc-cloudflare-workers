# hostlib/zstd: the zstd decoder (vendored)

These files are a copy of the zstd module of zig-libs. `hostlib/native/zstd.zig` uses them for the Native zstd ops. The research and the measurements are in `research/zstd-speed/README.md`.

| Item | Value |
| --- | --- |
| Source | https://github.com/zaxified/zig-libs, directory `modules/zstd/src/` |
| Commit | `ccde0637ddd031b962d91c7cff6dd4a0f531e348` (2026-11-01) |
| What it is | A pure Zig port of libzstd 1.5.7 (encoder and decoder). The platform uses only the decoder: `Decompressor`, the piece by piece API (`decompressContinue`, libzstd `ZSTD_decompressContinue`). |
| Licence | MIT (`LICENSE`, zig-libs). The port of libzstd is under the BSD licence of libzstd: `NOTICE` has its text. Both files go with the source and with the binary (the host). |
| Files | The 25 files that `decompress.zig` imports (directly and through other files). The encoder files are here because `ddict.zig` imports `cdict.zig`. The compiler builds only the code that the decoder calls. |
| Changes | None. Each file is byte equal to the file of the commit. `sha256sum *.zig \| sha256sum` gives `296addb86a034d342e0fc093ca4ed1a671cdd6e49f63e7b0b2a68148c4362238`. |
| Module | `zstd_dec`, root `decompress.zig`. `build.zig` builds it with ReleaseSafe (all bounds checks on), the rest of the host with ReleaseSmall. Every build of `hostlib` must give it: `build.zig`, `bench/8g/host-build/build.zig`, `bench/alloc-test.sh`, and the `zig test` step of `bench/test-all.sh`. |

## How to update

1. Copy the same 25 files from the new commit (`research/zstd-speed/fetch.sh` gets the source).
2. Put the new commit and the new hash in the table.
3. `newDec` in `hostlib/native/zstd.zig` checks the field list of the decoder state at compile time. If the fields changed, read the new `Decompressor.init` and change `newDec` to match it.
4. Run `zig test` of `hostlib/native/native_test.zig`, `research/zstd-speed/difffuzz` (the decoder against libzstd) and `research/zstd-speed/tagfuzz` (the ops against the old error tags), and `bench/test-all.sh`.
