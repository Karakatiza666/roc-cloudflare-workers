# Transition: from the npm setup to the Talon setup

Date: 2026-10-23, revised the same day with the decisions of the user (Talon study, section 12: `tln run` in Talon v1, no shell, `tln path`, project tools in `[tools]`, dependency order for `--each`). A plan, not done work. The Talon side is a proposal: `talon/research/talon-scripts/README.md` (the parent repository). A rule id with `PROPOSED` there (R-RUN, R-TG, R-PTH, R-IN8) is not in the Talon design yet. The gaps G1 to G7 are in `README.md` of this directory.

## Decisions (2026-10-23)

The user answered the questions of the Talon study (`talon/research/talon-scripts/README.md`, section 12). The effect on this plan:

| # | Decision | Effect here |
| --- | --- | --- |
| Q-S1 | `tln run` is in Talon v1 | The examples and the template use `talon.toml` `[scripts]` |
| Q-S2 | No shell in a step | Each step is one command (sections 3.1, 3.3) |
| Q-S3 | `tln path` | `roc-cfw` finds `js/` with `tln path pf` (section 5) |
| Q-S4 | Project tools in `[tools]` | `roc-cfw` is pinned in each project. CI uses the lock. No global install (sections 3, 6, 7) |
| Q-S5 | The R-SM2 stub for `tln init --platform` | `roc-cfw init` replaces the stub body (section 7) |
| Q-S6 | `--each` in dependency order | A Worker that reads another wasm declares `[run] after` (section 3.3) |
| Q-S8 | One `[build] target` | The platform has one target: no key needed |
| Q-S9 | No `tln run --dry-run` | None |
| Q-S10 | `in` steps and `--each` | The repo examples use `in` steps (section 3.3) |

## 1. Before and after

```text
Before (today)                                   After
--------------------------------------------     --------------------------------------------------
release:  <hash>.tar.zst  (platform)             release:  <hash>.tar.zst  (platform + js/)
          roc-cloudflare-workers-X.Y.Z.tgz        (no .tgz)
          (shim + cli.mjs: sync, init)

project:  app.roc        platform URL            project:  main.roc       platform URL + roc: pin
          package.json   shim .tgz URL, scripts            talon.toml     [tools] roc-cfw, [scripts]
          worker.js      import 'roc-cloud...'             worker.js      import './.roc-cfw/index.js'
          wrangler.toml                                    wrangler.toml  (no change)
          node_modules/  (npm install)                     .roc-cfw/      copy of js/ (gitignored)

commands: npm install                            commands: tln install
          npm run build                                    tln run build
          npx ... roc-cloudflare-workers init              tln init --platform ... ; tln add --tool ...
                                                           tln x roc-cfw -- init
```

| Part | Today | After | Pinned by |
| --- | --- | --- | --- |
| Platform | Header URL, set by hand | Header URL, `tln add --platform` | Header hash |
| Nightly | By hand | `roc:` pin in the header, the proxy selects it | Header |
| Shim JS (`js/*.js`) | npm tarball | `js/` in the platform bundle, copied to `.roc-cfw/` | Header hash (the same pin) |
| `sync` (manifest, `worker.js`, config check) | `js/cli.mjs` in the tarball, run by npm `bin` | `js/cli.mjs` in the platform bundle, run by `node` through `roc-cfw sync` | Header hash |
| `init` | `js/cli.mjs init` | `roc-cfw init` (separate tool), template in `js/template/` of the bundle | Tool: `[tools]` of the project. Template: header hash |
| Helper CLI | npm `bin` | `roc-cfw`: a Roc app on basic-cli, repository `Karakatiza666/roc-cloudflare-workers-cli` | `[tools] roc-cfw` of each project: a range (`ref`) and the locked release URL with its hash (`url`), Talon R-PT1. No global install |
| Task list | `package.json` `scripts` | `talon.toml` `[scripts]`, `tln run` | The repository |

## 2. Order of the work

The steps are in dependency order. A step with a Talon dependency waits for that Talon phase.

| Step | Owner | Work | Needs | Keeps today's setup working? |
| --- | --- | --- | --- | --- |
| 1 | Platform | Put `js/` in the platform bundle (section 4). Keep the `.tgz` for one release | Nothing | Yes |
| 2 | Platform | `cli.mjs`: `sync` only. `init` moves to the helper. Add `js/cfw.json` (`{ "api": 1 }`). `entryOf` writes the import as the relative path from `worker.js` to the directory of `cli.mjs` (`./.roc-cfw/index.js`), and the package name `roc-cloudflare-workers` only when `cli.mjs` is in `node_modules/` | Nothing | Yes (the import depends on where `cli.mjs` is) |
| 3 | Platform | Done (2026-10-23). Renamed `examples/hello/app.roc` to `main.roc` (G7): `js/cli.mjs` `init`, `scripts/bundle.sh`, `scripts/test_bundle.sh`, `examples/hello/package.json`, the docs | Nothing | Yes, after a change of the scripts that name `app.roc` |
| 4 | Helper | New repository `roc-cloudflare-workers-cli`: `roc-cfw shim`, `sync`, `init` (section 5) | basic-cli. `tln path` (step 6), or the cache rule as a fallback | Not used yet |
| 5 | Talon | G1: the build target (R-TG1 to R-TG6) | Talon P0 | n/a |
| 6 | Talon | `tln run`, `[scripts]`, `--each` order (R-RUN1 to R-RUN17, R-EA1 to R-EA8), `[tools]` (R-PT1 to R-PT16), `tln path` (R-PTH1 to R-PTH5) | Talon P1 | n/a |
| 7 | Platform | Examples and README to the Talon setup (section 3). Remove `package.json` of the examples | Steps 2 to 6 | No: this is the switch |
| 8 | Platform | CI and release (section 6). Remove the `.tgz` asset | Step 7 | n/a |

## 3. Files of each example

### 3.1 `examples/hello`

| File | Before | After |
| --- | --- | --- |
| `app.roc` | Path platform `../../platform/main.roc` | Renamed to `main.roc`. Same path platform in the repo (a URL in a user project) |
| `package.json` | Scripts `build`, `sync`, `dev`, `deploy`. Dependency: the `.tgz` URL | Removed |
| `talon.toml` | None | None in this directory: the repository root `talon.toml` holds the scripts (section 3.3) |
| `worker.js` | `import { makeHandler } from 'roc-cloudflare-workers';` | `import { makeHandler } from './.roc-cfw/index.js';` (written by `sync`) |
| `wrangler.toml` | As now | No change |
| `.gitignore` | None (the repo root ignores `.cache/`) | `.roc-cfw/`, `*.wasm` |
| `README.md` | npm steps | Talon steps (section 7) |
| `with_cbor.roc` | Test app | No change |

The template for a user project (`js/template/` in the bundle, used by `roc-cfw init`):

```text
main.roc         the body of examples/hello/main.roc (the helper keeps the header that tln init wrote)
wrangler.toml    examples/hello/wrangler.toml, with the name of the project
talon.toml       [scripts] below. `roc-cfw init` adds the table to the `talon.toml` that `tln add --tool` made, and keeps `[tools]`
.gitignore       app.wasm, .roc-cfw/, .wrangler/
```

```toml
# talon.toml of a user project
[tools]
roc-cfw = { ref = "Karakatiza666/roc-cloudflare-workers-cli@^1", url = "https://github.com/Karakatiza666/roc-cloudflare-workers-cli/releases/download/1.0.3/<hash>.tar.zst" }

[scripts]
build = ["roc build --target=wasm32 --no-cache --output=app.wasm main.roc", "roc-cfw sync"]
check = ["roc build --target=wasm32 --no-cache --output=app.wasm main.roc", "roc-cfw sync --check"]
dev = ["@build", "wrangler dev --local"]
deploy = ["@check", "wrangler deploy"]
```

### 3.2 `examples/auction` (two Workers in one directory)

| File | Before | After |
| --- | --- | --- |
| `web.roc`, `ledger.roc` | Path platform | No change. Both are workspace members (root `talon.toml`) |
| `Gavel.roc`, `LotRoom.roc` | Modules | No change. Not members: they have no `app` header (R-PD8) |
| `worker.js`, `worker-ledger.js` | `from 'roc-cloudflare-workers'` | `from './.roc-cfw/index.js'` (one copy for both Workers: one platform) |
| `wrangler-web.toml`, `wrangler-ledger.toml` | As now | No change |
| `README.md` "Build", "Deploy" | `roc build` lines, `roc-cloudflare-workers sync` | `tln run auction` from the root (section 3.3) |

Order: both `.wasm` files first, then each `sync`. A later `sync` that reads the wasm of the other Worker (for example to check `script_name` classes) then finds it.

### 3.3 Repository root `talon.toml` (new)

In the repository, a build inside `examples/auction/` gives `PathOutsideWorkspace` (the platform path goes out of the app directory). So the scripts of the examples run from the root, where `talon.toml` is.

```toml
[workspace]
members = ["examples/hello/main.roc", "examples/auction/web.roc", "examples/auction/ledger.roc"]

[tools]
roc-cfw = { ref = "Karakatiza666/roc-cloudflare-workers-cli@^1", url = "<release URL with hash>" }

[scripts]
hello = [
  "roc build --target=wasm32 --no-cache --output=examples/hello/app.wasm examples/hello/main.roc",
  { in = "examples/hello", run = "roc-cfw sync --js ../../js" },
]
auction = [
  "roc build --target=wasm32 --no-cache --output=examples/auction/web.wasm examples/auction/web.roc",
  "roc build --target=wasm32 --no-cache --output=examples/auction/ledger.wasm examples/auction/ledger.roc",
  { in = "examples/auction", run = "roc-cfw sync --file web.roc --wasm web.wasm --entry worker.js --config wrangler-web.toml --js ../../js" },
  { in = "examples/auction", run = "roc-cfw sync --file ledger.roc --wasm ledger.wasm --entry worker-ledger.js --config wrangler-ledger.toml --js ../../js" },
]
examples = ["@hello", "@auction"]
```

The examples use one root script and `in` steps, not `tln run --each`: a build must run from the root (`PathOutsideWorkspace`), and the 2 Workers of `auction` share one directory, so they are one node of `--each` (Talon R-EA1). A user repository with one directory for each Worker can use `--each` with dependency order:

```toml
# workers/web/talon.toml: web's sync reads ledger.wasm, so ledger runs first
[run]
after = ["../ledger"]
```

`tln run --each build` then runs `workers/ledger` before `workers/web`. Talon has no other order source than header path entries and `after`: no file-change detection, no cache, no parallel runs (Talon R-EA2 to R-EA7).

`--js <dir>`: a helper flag for this repository only. The path platform `../../platform/main.roc` makes `tln path pf` give `platform/`, and the JS is in `js/` of the root. A user project never needs the flag. The other way is a move of `js/` to `platform/js/`, which changes the paths of the tests and `bench/`. Not proposed.

## 4. The platform release

### 4.1 `scripts/bundle.sh`

| Part | Before | After |
| --- | --- | --- |
| Stage | `platform/*.roc`, `LICENSE`, `targets/wasm32/host.wasm` | The same, plus `js/*.js`, `js/cli.mjs`, `js/package.json` (only `"type": "module"`, so that `node` loads `.roc-cfw/*.js` as ES modules in a project with no `package.json`), `js/cfw.json`, `js/template/` |
| `roc bundle` file list | `main.roc LICENSE targets/wasm32/host.wasm` | Plus each file under `js/`. Tested: `roc bundle` and `roc unbundle` keep `.js`, `.mjs` and `.json` files at their paths (`talon/research/talon-scripts/probes/bundle-js/`) |
| Bundle check | No package copy, no `../` | The same, and each `js/` file is in the list |
| Step 5: npm pack, `release.json` | Makes `roc-cloudflare-workers-X.Y.Z.tgz` | Removed. `release.json` is not needed: the platform URL is in the header of the project |
| Last lines | `asset:`, `url:`, `shim:`, `shim_url:` | `asset:`, `url:` |

Size: the `js/` files are 186 KB today (without the template). The platform limit is 512 MB (Talon Design 2).

Talon reads only `main.roc` of a bundle (CLI R-DI7) and never runs a file of it (R-SE4). The helper reads `js/`, and `node` runs `js/cli.mjs` only when the user runs `roc-cfw sync`.

### 4.2 `release.yml` and `release-notes.md`

| File | Change |
| --- | --- |
| `release.yml` job `release` | `gh release create` with the bundle only. No `shim`, `shim_url` outputs |
| `release.yml` job `test-published` | `scripts/test_bundle.sh <url>` with one argument. It still installs Wrangler (`npm install -g wrangler`): an external program, not a project dependency |
| `release-notes.md` | Remove the `npm install @SHIM_URL@` block and the `.tgz` row. Add: `tln add --platform Karakatiza666/roc-cloudflare-workers@<tag>` (the tag of the release), and `tln add --tool Karakatiza666/roc-cloudflare-workers-cli` |

## 5. The helper repository

| Item | Value |
| --- | --- |
| Repository | `Karakatiza666/roc-cloudflare-workers-cli`. Its own repository: a Talon release has one `<hash>.tar.zst` asset (CLI R-DI4), and one group cannot hold a `platform` and an `app` (Resolution R-C4) |
| Language, platform | Roc, basic-cli. Packages: `roc-app-header` (read the header of the app file) |
| Release | An app bundle (`roc bundle`), so Talon builds it from the locked `url` of `[tools]` (Talon R-PT6, CLI R-T10). A project pins it with `tln add --tool`. Prebuilt binaries later (CLI R-T22, P3) |
| Platform of the tool | basic-cli (a native platform, Talon R-PT16) |
| Commands | `roc-cfw shim`, `roc-cfw sync [args]`, `roc-cfw init` (Talon proposal, section 6) |
| Contract with the bundle | `js/cfw.json` `api`. The helper supports a list of `api` numbers. A new `api` needs a helper release. A platform release with the same `api` needs none |
| Programs that it runs | `tln path <alias>`, `node .roc-cfw/cli.mjs sync ...`. It finds both in `PATH` |

What `roc-cfw sync` does:

```text
roc-cfw sync [--file main.roc] [--js <dir>] [sync args]
  |
  v
read the header of the app file -> the platform alias (pf)
  |
  v
--js given? --yes--> dir = <dir>
  | no
  v
dir = $(tln path pf)/js            (Talon R-PTH1; fetches when missing)
  |
  v
read dir/cfw.json: api supported? --no--> exit 2: "update roc-cfw: tln update roc-cfw"
  |
  v
.roc-cfw/.platform == the platform hash? --no--> copy dir/* to .roc-cfw/ (a temp, then rename), write .platform
  |
  v
node .roc-cfw/cli.mjs sync [sync args]   (exit code passes through)
```

`cli.mjs sync` keeps its exit codes: 0 good, 1 a part is missing or wrong, 2 a bad command line or no app.

## 6. CI

### 6.1 This repository

| File | Before | After |
| --- | --- | --- |
| `scripts/test_example.sh` | `npm install <shim .tgz>`, `./node_modules/.bin/roc-cloudflare-workers sync --check` | Copy `js/` (or `js/` of the extracted bundle) to `<project>/.roc-cfw/`, then `node .roc-cfw/cli.mjs sync --check`. No helper and no Talon needed: the test checks the platform files |
| `scripts/test_bundle.sh` | Arguments: bundle, shim | Argument: bundle. Step 2 takes `js/` from the bundle in the package cache (`$XDG_CACHE_HOME/roc/packages/<hash>/js/`), so the test proves that the bundle has the shim |
| `release.yml`, `tests` job | `npm install -g wrangler` | No change |
| New job (after Talon P1) | None | Install Talon at a fixed version (CLI R-IN6 form), `tln install --frozen` (it also builds `roc-cfw` from the locked `url` of the root `[tools]`), `tln run examples`, then `git diff --exit-code examples/` (the committed `worker.js` files are the files that `sync` writes) |

### 6.2 A user project

```yaml
jobs:
  check:
    runs-on: ubuntu-latest
    env:
      TALON_AUTO_INSTALL: 'yes'
    steps:
      - uses: actions/checkout@v4
      - run: curl -fsSL https://github.com/roc-talon/talon/releases/download/v<t>/install.sh | sh -s -- --yes --version <t>
      - run: tln install --frozen     # the closure, and roc-cfw from the locked url (no global install)
      - uses: actions/setup-node@v4
        with:
          node-version: '26'
      - run: npm install -g wrangler@<w>
      - run: tln run check
```

`tln install --frozen` fails with exit 14 when `[tools] roc-cfw` has no `url` or a `url` outside its range (Talon R-PT7). A run of `roc-cfw` makes no network call: the `url` is the lock (R-PT8). `tln audit` reports a yanked helper release.

`tln run check` fails the job when the build fails (exit 1 of `roc build`, also when it wrote the wasm) or when `sync --check` finds a change.

## 7. The user steps after the change

```sh
tln init --platform Karakatiza666/roc-cloudflare-workers    # main.roc (header + stub), roc: pin, CI file
tln add --tool Karakatiza666/roc-cloudflare-workers-cli     # talon.toml [tools] roc-cfw: range + locked url, built here
tln x roc-cfw -- init                                       # the project version (R-PT11): app body, wrangler.toml, [scripts], .gitignore
tln run build                                               # roc build, then roc-cfw sync
tln run dev                                                 # wrangler dev --local
```

Update of the platform:

```sh
tln update pf        # new header URL and hash
tln update roc-cfw   # optional: a new helper inside the ref range (a new url)
tln run build        # sync copies the new js/ (new hash), writes worker.js, checks wrangler.toml
```

## 8. What stays external

| Program | Why | Install |
| --- | --- | --- |
| Node, with JSPI (`WebAssembly.Suspending`). The tests use Node 26 | Wrangler runs on Node. `cli.mjs sync` runs the app in Node to get the manifest: the manifest is the reply of the app to the `Manifest` event (`js/runner.js` `manifestOf`), so a tool cannot read it with no execution | The user's choice (system package, nvm, `actions/setup-node`) |
| Wrangler | Bundle, `dev`, `deploy`, D1, R2, secrets | `npm install -g wrangler@<w>` on the machine. Not a project file |

## 9. Risks and checks

| Risk | Check |
| --- | --- |
| `roc-cfw` runs before `tln path` exists (Talon P1) | Fallback in the helper: compute `$XDG_CACHE_HOME/roc/packages/<hash>/` (Talon Design R-CR1) and run `roc check <app>` to fetch. Remove after Talon P1 |
| A user deletes the cache (`tln cache clean --all`) | `.roc-cfw/` is a copy, so `wrangler dev` still works. The next `roc-cfw sync` fetches again through `tln path` |
| `node` loads `.roc-cfw/*.js` as CommonJS | `js/package.json` with `"type": "module"` is in the copy (section 4.1) |
| `wrangler dev` watch and Windows symlinks | Not relevant: the copy has no symlink. Wrangler bundles a relative import from `.roc-cfw/` (probe `talon/research/talon-scripts/probes/wrangler-resolve/`, case a-copy) |
| An old helper and a new bundle `api` | The helper stops with exit 2 and names `tln update roc-cfw` (the project pin) |
| The global `roc-cfw` (if a user installed one) has another version than the project | Inside `tln run` and `tln x roc-cfw`, the project version wins (Talon R-PT12). A `roc-cfw` typed in a shell is the global one: the README says to use `tln x roc-cfw` |
| GC removes the built helper | Talon keeps it while the project is known (R-PT14). After `tln cache clean`, the next run builds it again |
| Talon does not accept `tln run` (question Q-S1 of the Talon study) | Keep the steps in a `Makefile` or in CI. Steps 1 to 4 and section 4 still remove npm from the project |

## Status of steps 1 and 2 (2026-10-24)

Done: step 1 (`js/` in the bundle) and step 2 (`cli.mjs` has `sync` only, `entryOf` import rule, `js/cfw.json`, `js/template/`). The `.tgz` step stays for one release (step 8 removes it). Not committed.

| File | Change |
| --- | --- |
| `js/cli.mjs` | `init` removed (`init` now gives exit 2 and the usage). New `shimImportOf(entryDir, cliDir)`: the package name `roc-cloudflare-workers` when `cliDir` has a `node_modules` part, else the relative path from the directory of the entry file to `cliDir` plus `/index.js`. `entryOf(m, wasmImport, shimImport)` takes the import as an argument |
| `js/cfw.json` | New: `{ "api": 1 }` |
| `js/template/` | New: `main.roc` (the body of `examples/hello/main.roc`: no `app` line, no path-platform note), `wrangler.toml` (as `examples/hello`, name `roc-hello`), `talon.toml` (`[scripts]` of 3.1 only), `.gitignore` (`app.wasm`, `.roc-cfw/`, `.wrangler/`) |
| `scripts/bundle.sh` | The stage has all of `js/`. `js/package.json` in the bundle is `{ "type": "module" }` (the source file is the npm package file). `roc bundle` gets each `js/` file. The bundle check fails when the `js/` files in the bundle list are not the files of `js/`. The `.tgz` has `*.js`, `cli.mjs`, `package.json`, `release.json` (no template: nothing reads it) |
| `scripts/test_bundle_js.sh` | New: `roc unbundle`, then lists and compares `js/`, `package.json`, `cfw.json`, template files |
| `scripts/test_bundle.sh` | Calls `test_bundle_js.sh` (a URL bundle is downloaded first) |
| `bench/cli-test.mjs` | Case 1c: the import is a relative path. `init` cases removed. New case 5: R-I1 (`.roc-cfw/` gives `./.roc-cfw/index.js`, also `../.roc-cfw/index.js` for an entry in `sub/`), R-I2 (`node_modules/roc-cloudflare-workers/` gives the package name) |
| `conformance/reverts.mjs` | The G7 `init` revert entry is replaced by 2 entries (R-I1, R-I2) |
| `bench/test-all.sh`, `README.md`, `MODULES.md`, `examples/hello/README.md` | Text: `init` moved to the helper |

Tests (2026-10-24, nightly `compat/last-stack-first-nightly`, Node 26.7):

| Test | Result |
| --- | --- |
| `node bench/cli-test.mjs bench/out` | all passed (68 checks) |
| `node bench/sync-cross-test.mjs` (the 3 link wasm files built first, they were not in `bench/out`) | all passed |
| `node bench/iface-test.mjs bench/out` (after a rebuild of the stale `conformance.wasm`) | all passed |
| `ZIG=<0.17> scripts/bundle.sh 0.0.0-local` | pass, 22 `js/` files in the bundle |
| `scripts/test_bundle_js.sh` | PASS |
| `scripts/test_bundle.sh` (builds the examples against the bundle, `test_example.sh` with the npm `.tgz`: `sync --check` with the package-name import, `wrangler dev` 6 routes, `deploy --dry-run`) | PASS |

Revert checks (each new test fails when its change is reverted):

| Revert | Caught by |
| --- | --- |
| `shimImportOf` without the `node_modules` rule (`conformance/reverts.mjs` entry R-I2) | `cli-test` 5b |
| `entryOf` import always the package name (entry R-I1) | `cli-test` 1c and 5a |
| `bundle.sh` stage without `js/cfw.json` | the bundle check of `bundle.sh` (exit 1) |
| The same, with that check removed by hand | `test_bundle_js.sh` (FAIL, `js/cfw.json` not in the bundle) |

Contract with the helper: no change. `cfw.json` `{ "api": 1 }`, `cli.mjs sync` arguments and exit codes 0, 1, 2 as before. Added: `cli.mjs init` is an error (exit 2). The template `main.roc` has no `app` header, so `roc-cfw init` must add the header that `tln init` wrote. `js/template/talon.toml` holds the `[scripts]` table only, with a leading comment line.

Open: the README no longer has a working `init` command for the npm setup until `roc-cfw` is released. Step 7 owns the README rewrite. `release.json` is still made and packed but nothing reads it.

## Status of steps 7 and 8 (no release) (2026-10-26)

Done: step 7 (examples and README to the Talon setup) and step 8 (no npm in the release). One change from the plan: the helper `roc-cfw` has no release, so this repository does not use it. A step of `talon.toml` runs `node ../../js/cli.mjs sync ...` directly. `sync` writes the shim import as the relative path from the entry file to the directory of `cli.mjs`, so the examples import `../../js/index.js`. Wrangler stays an external program (installed on the machine). Not committed. Nothing was released, deployed or pushed.

### What changed

| File | Change |
| --- | --- |
| `scripts/bundle.sh` | Default version `0.0.1-local` (Roc refuses `0.0.0`, finding C1 of `research/plugin-probes/FINDINGS-core.md`). A version `0.0.0*` gives exit 1. Step 5 removed (the npm `.tgz`, `release.json`). The last lines are `asset:` and `url:` only. The stage copies `js/` as it is (`js/package.json` is already `{ "type": "module" }`) |
| `js/package.json` | Only `{ "type": "module" }` |
| `js/cli.mjs` | `shimImportOf` has no `node_modules` branch: it gives the relative path only. The usage and the comments name `node cli.mjs sync`, not the npm command |
| `js/index.js` | The error text of a missing binding names `node .roc-cfw/cli.mjs sync`, not `npx` |
| `bench/cli-test.mjs`, `conformance/reverts.mjs` | Case 5b and revert entry R-I2 removed. R-I1 stays |
| `talon.toml` (new, root) | `[workspace] members` (3 apps), `[scripts]` `hello`, `auction`, `examples`. Steps are `roc build ...` and `{ in = "examples/...", run = "node ../../js/cli.mjs sync ..." }`. No `[tools]` table |
| `examples/hello/package.json` | Deleted. No other example had one |
| `examples/*/worker.js` (3 files) | Import `../../js/index.js` (written by `sync`) |
| `.gitignore`, `examples/hello/.gitignore`, `examples/auction/.gitignore` | `.roc-cfw/`, `*.wasm` (the root file loses the `examples/*` lines that the new files cover, and the `node_modules` line for examples) |
| `scripts/test_example.sh` | Takes `<app.wasm> [js dir]` (default: `js/`). Copies the directory to `<project>/.roc-cfw/`, runs `node .roc-cfw/cli.mjs sync` (it writes `worker.js`), `sync --check`, a check that the file is `examples/hello/worker.js` but for the import line, `wrangler dev --local` (6 requests) and `wrangler deploy --dry-run` |
| `scripts/test_bundle.sh` | One argument (a bundle file or an https URL). Step 2 takes `js/` from the unpacked bundle in the package cache (`$XDG_CACHE_HOME/roc/packages/<hash>/js/`) |
| `scripts/test_bundle_js.sh` | `js/package.json` is compared like the other files |
| `.github/workflows/release.yml`, `.github/release-notes.md` | No `shim`, `shim_url` outputs. `gh release create` with the bundle only. The notes have `tln add --platform ...@<tag>` (the `@TAG@` marker) and the manual copy of `js/`; the `.tgz` row is gone. `tln add --tool` waits for the helper release |
| `README.md`, `examples/hello/README.md`, `examples/auction/README.md`, `MODULES.md`, `API.md`, `PLAN.md` | Repo flow: `tln run hello`, `tln run auction`, `tln run examples`. User flow: the planned `roc-cfw` setup (marked as not released) and the manual way that works today (`cp -r <package cache>/<hash>/js .roc-cfw`, `node .roc-cfw/cli.mjs sync`). No `npm install` in a user doc. PLAN.md row "Examples on Talon" updated |

### How Talon ran here (local build, no network for the compiler)

| Item | Value |
| --- | --- |
| Talon | `/home/george/dev/Karakatiza666/talon/.work/bin/tln` (version 0.0.0 build) |
| Isolated state | `XDG_CACHE_HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME` = `.cache/talon-run/{cache,config,data}` (the variables of Talon CLI R-EV13 that `tests/lib.sh` sets), `TALON_REGISTRY=direct`, `TALON_AUTO_INSTALL=no`. The packages `http` and `cbor` were copied into `.cache/talon-run/cache/roc/packages/` first |
| Compiler | `tln roc link nightly-2026-10-19-601b54c .cache/nightlies/nightly-2026-10-19-601b54c/roc` (it makes `link-nightly-2026-10-19-601b54c` and downloads nothing), then `tln roc default link-nightly-2026-10-19-601b54c`. The examples have a path platform, so the header has no `roc:` pin. Resolution 13 ranks 6 (the global default) selects the link. A `roc` step in `tln run` runs through the proxy and gets it |
| Run | `tln run examples`: exit 0. `tln run hello`: exit 0 (7 s) |

Note: `sync` of `auction` prints a note that 18 Wrangler configs have the name `auction-ledger` (and `auction-web`): the copies in `research/g1a-size/work/*/app/`. The link check is then skipped. This is the behavior of `sync` before this change. It is not an error.

### Tests

| Test | Result |
| --- | --- |
| `node bench/cli-test.mjs bench/out` | all passed (68 PASS lines, with 5b removed) |
| `node bench/sync-cross-test.mjs` | all passed (24) |
| `node bench/iface-test.mjs bench/out` | all passed (28). No stale wasm this time |
| `ZIG=/home/george/.local/zig/zig-x86_64-linux-0.17.0/zig scripts/bundle.sh` (default version `0.0.1-local`) | exit 0, 22 `js/` files in the bundle, 2 output lines |
| `roc check` of `examples/hello/main.roc` with the platform URL of version `0.0.1-local` (the bundle put in a package cache with `roc unbundle`) | No errors found. The same URL with `0.0.0-local` gives "invalid package version ... reserved version 0.0.0" |
| `scripts/test_bundle_js.sh` | PASS |
| `scripts/test_bundle.sh dist/<hash>.tar.zst` | PASS (the 2 apps build against the bundle, `sync` and `sync --check` on the copy with `.roc-cfw/`, `wrangler dev --local` 6 routes, `wrangler deploy --dry-run`) |
| `tln run examples`, then a compare of `git diff examples/` before and after | exit 0, no change: the committed `worker.js` files are what `sync` writes |
| `node js/cli.mjs sync --check` for `hello`, `web` and `ledger` | exit 0 for each |

### Revert checks

The full sweep of `conformance/reverts.mjs` was not run. The filtered run is `ROC=<nightly> node conformance/reverts.mjs "TRANSITION 2 R-I1"`. Each file was restored after each check.

| Revert | Caught by |
| --- | --- |
| Entry R-I1 (the import is always the package name), `reverts.mjs` filtered run | `cli-test` 1c (the clean tree passed first) |
| Hand: `shimImportOf` gives `./.roc-cfw/index.js` always | `cli-test` 5c (`sub/` entry), and `sync --check` of `examples/hello` (exit 1) |
| Hand: default version of `bundle.sh` back to `0.0.0-local` | The new guard of `bundle.sh` (exit 1, "bad version"). `roc check` refuses that URL |
| Hand: `js/package.json` with an npm field | `test_bundle_js.sh` (FAIL: `js/package.json` differs from the bundle) |
| Hand: `examples/hello/worker.js` with the old package import | `test_example.sh` (FAIL: worker.js of sync is not examples/hello/worker.js) |
| Hand: the `hello` script step without `in` | `tln run hello` exit 2 (`sync` runs in the root, finds no app) |
| Hand: `examples/auction/worker.js` with the old package import | `sync --check` exit 1 |

### What waits for a release

| Item | Waits for |
| --- | --- |
| `[tools]` pin of `roc-cfw` in the root `talon.toml` and in `js/template/talon.toml` (section 3.3 form: `ref` and a locked `url`), and `tln add --tool` in the release notes | The first release of the helper repository |
| The CI job of 6.1 (`tln install --frozen`, `tln run examples`, `git diff --exit-code examples/`) | A Talon release (CLI R-IN6 form, a fixed version) |
| The first platform release (`release.yml` has never run; `test-published` runs `test_bundle.sh <url>`) | The user's decision |
| `--js` flag of `roc-cfw sync` (section 3.3) | Not needed any more in this repository: `node ../../js/cli.mjs` is direct. A user project needs no flag |
| The README user flow with `roc-cfw` | The helper release. The manual flow works today |

## Change of `sync` (2026-10-26): V8 and V21

| Item | Change |
| --- | --- |
| Arguments | `cli.mjs sync` takes `--file <app>.roc` (the app source for the check of unlisted handlers). With no `--file`: `<wasm name>.roc` next to the wasm file, else `main.roc`. The helper `roc-cfw sync --file ...` must pass `--file` on to `cli.mjs` (it reads it for the header too) |
| Exit codes | The same: 0, 1, 2. An unlisted handler is exit 0 (a warning) and exit 1 with `--check`. A `--file` that is not there is exit 2 |
| Entry file | With `worker.options.js` next to the entry file, the entry file imports it (`makeHandler(app, options)`). The helper writes no options file. `roc-cfw sync --check` checks the import |
| `cfw.json` | `{ "api": 1 }` stays: the arguments and the exit codes are compatible |
