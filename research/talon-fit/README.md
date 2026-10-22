# Talon fit check: can the Workers examples move from npm scripts to Talon?

Date: 2026-10-23. Read-only check. No Talon file was changed.

Sources, as in the Talon working tree on this date (the design files have uncommitted edits):

| Short name | File |
| --- | --- |
| Design | `DESIGN.md` |
| CLI | `DESIGN-CLI.md` |
| Resolution | `DESIGN-RESOLUTION.md` |
| Registry | `DESIGN-REGISTRY.md` |

Platform side: `README.md` "Use it", `MODULES.md` section 3 (row `roc-cloudflare-workers`), `js/cli.mjs` (`sync`, `init`), `examples/hello/`, `scripts/bundle.sh`, `.github/workflows/release.yml`, `.github/release-notes.md`.

A path such as `CLI R-PX3` is the rule id in the file `DESIGN-CLI.md`.

## 1. Result in one table

| # | Need | Verdict | Where, or what is missing |
| --- | --- | --- | --- |
| 1 | Install and pin the platform and the nightly | Supported, with 2 notes | See 2.1 |
| 2 | Build for `wasm32` with `--no-cache` and `--output` | Partly | `roc` flags pass through (supported). The check ladder builds for the host target, so a wasm32-only platform fails it. Gap G1. See 2.2 |
| 3a | Step after the build (`sync`), `sync --check` in CI | Not covered, by design | Talon has no run command and no hooks. Keep the npm script. Gap G2. See 2.3 |
| 3b | Monorepo of several Workers | Partly | Workspaces fit the dependency side. They do not run or order build steps. See 2.3 |
| 4 | Ship the shim and the CLI as part of the platform | Partly. The bundle can hold the files. Nothing can run or find them | Gap G3. Messy. Recommend a separate tool. See 2.4 and section 4 |
| 5 | `init` from a template | Partly | `tln init --platform` writes only `main.roc` and a CI file. Gap G4. See 2.5 |
| 6 | Other things the examples use | Node, npm, Wrangler stay outside. See 2.6 | |

## 2. Each need

### 2.1 Install and pin the platform and the nightly: Supported

| Step | Talon rule | Check against the platform |
| --- | --- | --- |
| `tln add --platform Karakatiza666/roc-cloudflare-workers` writes the URL and the hash under the alias `pf` | CLI R-AD29, R-AD30. Replace an old platform: R-AD31. Release URL only: Design R-H3 | The platform header starts with `platform`, so its kind is right (Resolution R-C4) |
| The release is a candidate | CLI R-DI3 (no draft, no prerelease), R-DI4 (one `<hash>.tar.zst` asset), R-DI5 (one `X.Y.Z` run in the URL) | `scripts/bundle.sh` makes one `<hash>.tar.zst`. The second asset `roc-cloudflare-workers-X.Y.Z.tgz` is not a package name, so R-DI4 ignores it. `release.yml` marks `X.Y.Z-pre` as prerelease, so R-DI3 skips it |
| The nightly goes in the header as `roc:` | Design R-H6, Resolution R-RP3 | |
| Select and install the nightly | Resolution R-SO3 (header pin), CLI R-CM15 (`tln roc install/use/default`), consent R-DL1 to R-DL5 | `compat/last-stack-first-nightly` today holds the nightly of the platform |
| CI reproduces the header | CLI R-FL13 (`tln install --frozen`), Resolution R-LF1 | CI sets `TALON_AUTO_INSTALL=yes` (CLI R-DL9) |
| Several apps use one platform version | Design R-WS9 | See 2.3 |

Notes for 2.1:

| Note | Detail |
| --- | --- |
| Minimum nightly | The platform needs a nightly with the stack-first layout (`NOT_STACK_FIRST` in `js/runner.js`). A compile check cannot see this. A `roc:` pin in the platform header is only a hint (Design 2, R-EF1 rank 3). The user can set a lower bound: `[toolchain] roc = ">=nightly-2026-10-19-601b54c"` (Resolution R-NS7, R-SO4). The platform cannot publish a bound. A wrong nightly gives an explicit error at `sync` (exit 2, `NOT_STACK_FIRST`) and not a silent fault. No Talon change proposed |
| `app.roc` is not `main.roc` | Talon finds `main.roc` or a workspace member file (CLI R-PD4). The examples use `app.roc`. Use `--file app.roc`, or name the file `main.roc`. The `roc` proxy accepts any file name (CLI R-PD7). Platform side: name the template file `main.roc`, or list `app.roc` as a workspace member |
| Path platform in the repo examples | `examples/hello/app.roc` uses `../../platform/main.roc`. Talon calls it a foreign entry and never writes it (Design R-H4, R-H7). It stays a path in the repo tests. `tln add --platform` replaces it with a URL (CLI R-AD31) |

### 2.2 Build for wasm32: Partly

| Part | Verdict | Rule |
| --- | --- | --- |
| `roc build --target=wasm32 --no-cache --output=app.wasm app.roc` | Supported | The proxy gives every roc command and flag to the selected compiler with no change, and the exit code passes through (CLI R-PX2, R-PX3). The target file is the first `.roc` argument (R-PD7) |
| `--no-cache` | Supported | A roc flag. Nothing in Talon uses it |
| A build error still writes `app.wasm` and exits 1 | Supported | The exit code passes through (R-PX2). The npm script already stops on it |
| The check ladder on a wasm32-only platform | Not covered. Gap G1 | Step 3 is `roc build main.roc --output=<tmp>` "for the host target" (Resolution R-LD5, `DESIGN-RESOLUTION.md:99`, diagram `:337`). The platform has only `targets: { wasm32 }`. A build for the host target fails. R-LD5 blames the platform for that target, and Talon stores the fail for (hash, nightly, target) (R-P4, `:203`). The bot smoke rows of R-SM6 (`:177`) work the same way for the platform. No rule says where the target of a project build comes from. `--no-check` skips the check (R-BL6) but also skips the `roc:` pin (Design R-H6) |

### 2.3 Step after the build, CI, monorepo: Not covered (by design) and Partly

| Part | Verdict | Detail |
| --- | --- | --- |
| Run `roc-cloudflare-workers sync` after `roc build` | Not covered | The command table (CLI R-CM1 to R-CM23) has no `run`, no `exec`, no script table, no hook. Bun has `bun run`. Design 3 adopts other Bun commands and not this one. Design N2: Talon calls `roc` and does not replace it. `tln x` and `tln tool` run Roc apps only (CLI R-T2, R-T10) |
| `sync` is Node | Outside Talon | `sync` loads `app.wasm` in Node with `new WebAssembly.Module` and runs `manifestOf` (`js/cli.mjs:392`). A Roc tool cannot do this. R-T2 names this case: "A wasm platform, such as `cloudflare-workers`, makes no CLI" |
| `sync --check` in CI | Supported as a script step | CI runs `tln install --frozen`, `roc build ...`, then `sync --check`. The CI file of `tln init` has `roc check` and `roc test` only (CLI R-IN6). The user adds the build and `sync --check` steps |
| Several Workers in one repo, one dependency set | Supported | `[workspace] members` with explicit files. One variable for each platform group, so all Workers share one platform version (Design R-WS9). One nightly for the workspace (R-WS4, R-WS13). `tln update` writes each member (R-WS11). The design shows `members` as patterns (Design 4.4). Write file paths with no wildcard, for example `examples/auction/web.roc` and `ledger.roc`: a pattern such as `examples/auction/*.roc` also takes `Gavel.roc` and `LotRoom.roc`, which are modules, and R-PD8 stops on a file with no `app` header |
| Build order, a second Worker's wasm for `sync`, per-member commands | Not covered | A workspace is a resolution scope only. Talon runs nothing for a member, and has no command that lists members for a script. The paths of the two Workers stay in `sync` flags (`--wasm`, `--config`, `--entry` exist today) or in a script |

### 2.4 Ship the JS side with the platform: Partly

What the design has, for each question of the brief:

| Question | Answer | Where |
| --- | --- | --- |
| A notion of tools or commands that a package or platform ships | No. A tool is a Roc app that Talon builds from source and puts on `PATH` | CLI 6.4, R-T1, R-T2, R-T10 |
| Non-Roc files in a package bundle | Yes. A bundle unpacks to `packages/<hash>/` with all files. `host.wasm` and `LICENSE` are in the platform bundle today (`scripts/bundle.sh` stage). Cached packages also hold `*.md` files. Limit 512 MB for a platform. Talon reads only `main.roc` (R-DI7) and never the other files | CLI R-FE2, R-FE3, R-DI7. Design 2 (limits row). Not tested here: a `.js` or `.mjs` file in a bundle. Test it before use |
| Run a package executable | No. Design R-SE4: "Talon never runs the output" (probes). `tln x` runs a built Roc app | CLI R-X4 |
| A hook after a build or an install | No | CLI R-CM1 to R-CM23 |
| Find the unpacked platform directory | Only by rule: `$XDG_CACHE_HOME/roc/packages/<hash>/` with the hash from the header URL (Design R-CR1). No command prints it | Design 2.2 |
| Keep the directory while a project uses it | Yes. GC keeps `packages/<hash>/` for a known project | CLI R-GC4, R-PD9 |

The shim has a second problem that Talon cannot solve. Wrangler bundles `worker.js`, and `worker.js` imports `roc-cloudflare-workers`. Wrangler finds it in `node_modules`, or through an alias in the Wrangler config. The Talon cache path has the hash and the user home in it. A committed alias to it would not work on another machine. So the shim stays an npm package (or `sync` copies it into the project), also if the bundle holds it.

### 2.5 `init`: Partly

| Part | Verdict | Rule |
| --- | --- | --- |
| New project with the newest platform release and a nightly that passes the ladder | Supported | CLI R-IN1 (`--platform <name>`), R-IN2, R-IN4 |
| Files of the template | Not covered | R-IN1 gives only the template kind (`app` or `package`). `tln init` writes `main.roc` (R-PD15) and a CI file (R-IN6). It writes no `worker.js`, `wrangler.toml` or `package.json`. The text of `main.roc` for a platform other than basic-cli is not in the design |
| A step that makes `main.roc` for a platform | Partly | Resolution R-SM2 makes a stub app from `requires`, but it is a crash stub for smoke builds, not a template |
| The ladder of R-IN2 on the template | Same gap as G1 | The new nightly would be checked with a host-target build |

### 2.6 Other things the examples use

| Item | Talon manages? | Note |
| --- | --- | --- |
| Roc compiler (nightly) | Yes | CLI 6.2, 6.3 |
| Platform and the packages in its header (`http`, `cbor`) | Yes | Closure and MVS (Design 2). The app has no `http` or `cbor` entry |
| Zig 0.17 (platform development only) | Partly | CLI 6.6 installs Zig only to build a compiler from source. `scripts/bundle.sh` needs `ZIG` for the host. Not an app user need |
| Node, npm, `package.json` | No | Needed for `sync`, the shim and Wrangler |
| Wrangler, workerd, `wrangler.toml`, D1 and R2 resources, deploy | No | Outside Talon |
| The npm shim package | No | Talon has no npm concept |
| Version equal for platform and shim | No | See G5 |
| Publish of a platform release | Partly | `tln publish` (CLI R-CM13, Registry 7) registers a release. It does not make the bundle or the tarball |
| `roc` inside npm scripts | Supported | After `tln setup`, `roc` is the proxy (CLI R-PX1). In CI, `TALON_AUTO_INSTALL=yes` (R-DL9). In a non-interactive run with no compiler, R-DL8 gives exit code 13 |

## 3. Gaps and the smallest change

| Gap | Need | Smallest change | Clean? |
| --- | --- | --- | --- |
| G1 | 2, 5: the ladder builds for the host target | Name the target of a project build. Proposal: R-LD5 builds for the host target when the platform `targets` has it, else for the one target that the platform has, else Talon stops with exit code 2 and names `[build] target = "<t>"` in `talon.toml` (intent only, G2 holds). The same key can set the target of the build for R-P4, R-BS1, R-SM3 | Clean. The keys already have a target field: R-P4, R-BS1, R-SM6, `artifact_targets` (Registry R-RE20), `wasm32` has code 34 (Registry `:421`). Only the choice of the target is missing |
| G2 | 3a: a step after the build | No change. Keep `package.json` scripts, a Makefile or CI steps: `roc build ... && roc-cloudflare-workers sync` | Not applicable. A run command or a hook makes Talon a task runner (N2). Recommend: leave it |
| G3 | 4: CLI and shim shipped with the platform and run by `tln` | None. Use a separate tool (section 4) | Messy. Leave it |
| G4 | 5: template files | None in Talon. Keep `roc-cloudflare-workers init` (writes the 4 files with the URLs of `release.json`). After G1, `tln init --platform` can make the ladder-checked `main.roc` and the CI file | Keep separate |
| G5 | 6: platform and shim are two pins (a header URL and an npm URL) that must have one version (`.github/release-notes.md`, "must have the same version") | Platform side only: `sync` compares the platform URL in the app header with `release.json.platform`, and prints the exact `npm install <shim URL>` for the version of the header when they differ. The shim URL follows from the platform URL: same tag, file `roc-cloudflare-workers-<tag>.tgz` (`scripts/bundle.sh`). `tln update` of `pf` then gives a clear next step | Clean. No Talon change |
| G6 | 1: a minimum nightly of the platform | None. The user sets `[toolchain] roc = ">=..."`. `init` of the platform can write it into `talon.toml` | Clean. A platform-set bound would change the rank of `roc:` hints (Design R-EF1). Do not do it |
| G7 | 1: file name `app.roc` | Platform side: name the template file `main.roc` | Clean |

## 4. Why not ship the CLI inside the platform (G3)

The change would be: the platform bundle holds `js/cli.mjs` and `js/*.js`, and Talon has a command that runs a command that a package declares (for example `tln run pf sync`).

| What it needs | Conflict with the current design |
| --- | --- |
| A manifest of commands in the bundle, read by Talon | Talon reads only the `main.roc` header of a package and keeps no second copy of facts (CLI R-DI7). A new file format, a new reader, a new field in the registry artifact record (Registry R-RE1) |
| A command that locates and runs a file of a package | Talon runs only Roc apps that it built (CLI R-T2, R-T10, R-X4). New run rules, new exit codes, new `Fx` effects and tests (`TESTING.md` 2) |
| An interpreter | `sync` needs Node, which Talon would not manage. CLI 6.4 gives this as the problem of `npm i -g`: a script runs with the `node` that is on `PATH` now. The design avoids it with native tools |
| A trust rule for code that Talon runs from a package | Design R-SE4 says probes never run package output. R-SE7 only prints a notice for native host files. A new threat row, a new consent prompt (CLI 4) and a new `--json` field are needed |
| Where the files are | The directory is `packages/<hash>/` under the cache. GC can remove it (CLI R-GC4). The path has the user home in it |
| The shim for Wrangler | Still needs `node_modules` or a copy in the project (section 2.4). So the second pin does not go away |
| Scope | Talon becomes a task runner and a plugin host (N2, Design 3 and `DESIGN_OVERVIEW.md` "Left to others") |

The gain is one pin in place of two. G5 gets most of that gain with no Talon change. So the recommendation is: leave G3. Keep the npm package `roc-cloudflare-workers` (shim, `sync`, `init`) as a separate tool, released with the platform as today (`scripts/bundle.sh`, `release.yml`).

A smaller Talon addition exists and is not needed now: a read-only `tln path <alias>` that prints the unpacked directory of a header entry. It adds no run rule and no trust change. It does not solve the Wrangler import (section 2.4), so it has no use here.

## 5. What the examples look like after the move

| Today (`examples/hello/package.json`) | With Talon |
| --- | --- |
| `roc` from `PATH`, the nightly by hand | `tln setup` once. `roc:` pin in the header selects the nightly (CLI R-PX2, R-SO3) |
| Platform URL and hash by hand | `tln add --platform Karakatiza666/roc-cloudflare-workers`, `tln update pf` |
| `"build": "roc build --target=wasm32 --no-cache --output=app.wasm app.roc && roc-cloudflare-workers sync"` | Same line. `roc` is the proxy |
| CI: install nightly by script | `tln install --frozen` with `TALON_AUTO_INSTALL=yes`, then the build, then `sync --check` |
| Many Workers | `talon.toml` with `[workspace] members = [...]` for one platform version and one nightly |
| `npm install <shim tgz URL>` | Same. Version check by G5 |

Work to do, in order:

| Order | Owner | Item |
| --- | --- | --- |
| 1 | Talon design (human review, TW17) | G1: the target of a project build |
| 2 | Platform | G5: the version check in `sync`. G7: template file name `main.roc` |
| 3 | Platform | Move the example CI to `tln install --frozen` after G1 is done |
