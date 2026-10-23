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
| 3 | Platform | Rename `examples/hello/app.roc` to `main.roc` (G7) | Nothing | Yes, after a change of the scripts that name `app.roc` |
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
