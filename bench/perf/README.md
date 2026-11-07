# Platform performance bench (per PR)

A bench of the platform on a real app: the Talon registry Worker. It tracks the cost of a request and the size of `app.wasm` for each commit, and it fails a PR whose change makes small requests more expensive. The goal is to stay inside the 10 ms CPU limit of the free plan.

## Files

| File | Use |
| --- | --- |
| `run.mjs` | Builds the app on this checkout, serves it in Miniflare, runs the scenarios, appends rows |
| `check.mjs` | The budget check. Exit 1 on a regression. Writes a markdown table (also to `$GITHUB_STEP_SUMMARY`) |
| `edge.mjs` | The edge part (post-merge job only): deploy to the bench Worker, send 400 requests, read the CPU quantiles from the Workers analytics |
| `chart.mjs` | Makes `results/CHART.md` (Mermaid `xychart-beta`) from the rows |
| `rows.mjs` | Shared code: read rows, CSV export |
| `budget.json` | Thresholds and the calibration of instructions to ms |
| `corpus/` | The pinned input (below) |
| `results/rows.jsonl`, `rows.csv`, `CHART.md` | The rows (append only), the CSV copy, the charts |
| `../../.github/workflows/perf.yml` | The workflow (not enabled) |

## Corpus (pinned, no parent repo, no token)

| Part | What | Size |
| --- | --- | --- |
| `corpus/app/` | Roc source of the registry Worker: `worker/*.roc`, `worker/lib`, `worker/sql`, `packages/records` | 772 KB |
| `corpus/db/` | Migrations `0001_init.sql`, `0002_triggers.sql` and `seed.sql` (209 releases, 7 nightlies, compat rows) | 328 KB |
| `corpus/scenarios/` | `small`, `search`, `releases`, `closure`, `compat`, `mixed-ro` (JSONL, as `talon/research/bench`) | 172 KB |
| `corpus/wrangler.toml` | The test config of the registry (queue producer `INDEX`, no consumer) | 1 KB |
| Total | 1.04 MB (1,040,291 bytes), 0.22 MB packed | |

Source: `roc-talon/talon` commit `e83e2305` (slices 227 and 228: the 3.39 MB app), copied with `git archive` (no working-tree edits): `worker/` (no tests) to `app/`, `packages/records/` (no tests) to `app/records/`, with the 3 header lines of `app/main.roc` kept (local `pf`, `records` path, `roc` pin) and the `records` path of `app/lib/main.roc` set to `../records/main.roc`; the scenarios made from `registry.roc-talon.org` on 2026-11-07. The code is the same owner and license (UPL 1.0) as this repository. The app imports the generic packages by release URL, so a build needs network (CI has it).

How a platform change reaches the app: the source of the app is pinned, not the wasm. `run.mjs` copies `corpus/app` to `<checkout>/.cache/perf/app`, points its `pf` line at `<checkout>/platform/main.roc`, runs `zig build` (the host of the checkout) and `roc build --opt=speed`. The shim is `js/` of the checkout (`startApp` takes it as `shim`). So one run measures the host, the platform Roc code and the shim of exactly that checkout. A build takes 3.5 to 5 minutes. The pinned wasm would not see a platform change, so it is not used.

When the app needs a change (new registry code), copy the files again and set the `roc:` pin in `corpus/app/main.roc` to the nightly of `compat/last-stack-first-nightly`.

## Run

```
export ZIG=<zig 0.17>             # ROC defaults to bench/get-roc.sh (needs gh)
node bench/perf/run.mjs           # build, 3 rounds of all scenarios, append rows
node bench/perf/run.mjs --wasm app.wasm --shim js --rounds 1 --scenarios small --out /tmp/rows.jsonl
node bench/perf/check.mjs --head head.jsonl --base base.jsonl
node bench/perf/chart.mjs
```

Needs `perf` for the main metric, and the Miniflare of a global wrangler (`MINIFLARE=<dir>` otherwise). Node 26.

## What a round does

| Step | Detail |
| --- | --- |
| Fresh Miniflare | `startApp` (js/test.mjs): app, migrations, seed, stats header on, clock fixed at 2026-11-07T12:00:00Z |
| Idle rate | `perf stat` of the workerd process for 1 s. Subtracted from each window (rate times window time) |
| Cold | The first request (`GET /v1/toolchains`), counted alone. Only for `small` |
| Warm-up | 600 requests. V8 tiers up the wasm in this time: `small` costs 7.4 M instructions after 30 requests and 3.6 M after 600 |
| Measured | 2000 requests (`small`), 1000 (`search`, `releases`, `compat`), 800 (`mixed-ro`), 500 (`closure`) |

The count is the workerd process only (user and kernel, all threads). The node process (the test driver) is not in it. The workerd process also has Miniflare and the local D1, which the edge does not have: about 60 % of its CPU (research/regprof/README.md). So the numbers follow the platform, but are not edge ms.

## Rows

One row for each (commit, scenario, metric), in `results/rows.jsonl`. `results/rows.csv` is the same table.

| Column | Meaning |
| --- | --- |
| `commit` | Short hash, `+dirty` when the tree has changes outside `bench/perf/results` and `research/` |
| `date`, `nightly` | UTC time, the Roc nightly of `compat/last-stack-first-nightly` |
| `label` | Free text (`--label`) |
| `where` | `local` (Miniflare, this bench) or `edge` (the real runtime, `edge.mjs`). A row with no `where` is `local` |
| `scenario` | A scenario name, or `static` |
| `metric`, `unit` | See below |
| `value` | Median of the rounds |
| `requests`, `rounds`, `min`, `max` | Measured requests, number of rounds, range of the rounds |
| `source` | `perf`, `proc`, `stats` or `static` |

| Metric | Scenario | Source | Meaning |
| --- | --- | --- | --- |
| `ins_per_req` | each | perf | Instructions of workerd for each request. The main metric |
| `cold_first_ins` | small | perf | Instructions of the first request of a fresh isolate |
| `cold_extra_ins` | small | perf | `cold_first_ins` minus `ins_per_req` (the start cost: lazy wasm compile, first D1 use) |
| `cpu_ms_per_req` | each | proc | CPU time of workerd from `/proc`. Information only (noise 10 to 25 %) |
| `allocs_per_req`, `alloc_bytes_per_req` | each | stats | Allocator calls and bytes of the Roc heap for each request (header `x-roc-stats`). Exact |
| `mem_peak_bytes` | each | stats | Largest size of the wasm memory |
| `app_wasm_bytes`, `largest_fn_bytes`, `wasm_functions` | static | static | Size of `app.wasm`, the largest function body (it sets the lazy compile time), function count |

## Noise (A/A, same wasm, 6 runs of 1 round, machine shared with other builds)

| Metric | Scenario | CV | Range of 6 |
| --- | --- | --- | --- |
| `ins_per_req` | `small` | 0.38 % | 1.0 % |
| `ins_per_req` | `search`, `releases`, `compat` | 0.6 to 0.95 % | 1.5 to 2.9 % |
| `ins_per_req` | `closure` | 0.50 % | 1.2 % |
| `ins_per_req` | `mixed-ro` | 0.10 % | 0.2 % |
| `cold_first_ins` | `small` | 0.09 % | 0.26 % |
| `allocs_per_req`, `mem_peak_bytes`, sizes | all | 0 % | 0 % (`releases` memory peak moves with GC timing in the first run) |
| `cpu_ms_per_req` | all | 9 to 17 % | 22 to 40 % |

CPU ms is not usable as a gate on a shared machine. Instructions are. A short measured window is worse: `small` with 400 requests had a range of 4.3 %, with 2000 requests 1.0 %.

## Budget (`budget.json`)

| Rule | Value | Why |
| --- | --- | --- |
| `small` `ins_per_req` | at most +3 % against the base | 3 times the A/A range of one run. The median of 3 runs is used |
| other scenarios `ins_per_req` | at most +5 % | A/A range up to 2.9 % |
| `small` `cold_first_ins` | at most +3 % | A/A range 0.26 % |
| `allocs_per_req` | at most +1 % | Exact. A new allocation in a small request shows at once |
| `app_wasm_bytes` | at most +2 % | Exact |
| `largest_fn_bytes` | at most +5 % | Exact |
| `small` `ins_per_req` absolute | at most 1 ms of estimated edge CPU | 10 % of the limit. Now 0.48 ms |
| `closure`, `mixed-ro` absolute | at most 4 ms, 3 ms | 40 % and 30 % of the limit. Now 2.6 ms and 2.0 ms |
| `small` `cold_first_ins` absolute | at most 75 ms (target 10 ms, report only) | The first request of a fresh isolate is now 56 ms of the same unit, so the target of 10 ms is not met. The limit stops it from growing |

The estimate of edge ms: `instructions / calibration.ins_per_ms * edge_share`. `ins_per_ms` is 3.0 M (the dev machine: `small` is 3.6 M instructions and 1.1 to 1.2 ms of CPU). `edge_share` is 0.4 for the steady state (the user Worker is about 40 % of the workerd CPU, research/regprof/README.md) and 1 for the cold request. This is a guard rail in one unit, not a promise about the edge: confirm it with `wrangler tail` CPU times of the bench deployment (`worker/wrangler.bench.toml`) and change `ins_per_ms`. A new absolute value is a decision for the owner of the budget.

A relative rule needs a base from the same machine. The CI job builds the base and the head of the PR, runs both in turn 3 times on one runner, and compares the medians. A row of an older run on another machine is never a base.

## Without perf

`perf stat` needs counters. A hosted GitHub runner is a VM, and it may give none (the workflow tries `linux-tools` and `kernel.perf_event_paranoid=-1`). Then `run.mjs` prints `source: proc`, and writes `cpu_ms_per_req` and `cold_first_cpu_ms` with the source `proc` instead of the instruction rows. `check.mjs` then compares these with the thresholds times `proc_factor` (4) and skips the absolute rules. The allocation, memory and size rows stay exact in both modes. They are the safe gate when CPU is noisy. Rows of different sources are never compared: `chart.mjs` draws only `perf` rows in the instruction charts.

| Metric | Comparable between runs on different machines | Between the base and the head of one job |
| --- | --- | --- |
| `ins_per_req` (perf) | Only on the same CPU type | Yes |
| `cpu_ms_per_req` (proc) | No | Yes, with wide thresholds |
| `allocs_per_req`, `mem_peak_bytes`, sizes | Yes | Yes |

## Edge CPU (optional, after a merge)

The `edge` job of `perf.yml` runs only on a push to main, and only when the repository variable `PERF_EDGE` is `true`. It needs the secrets `CLOUDFLARE_API_TOKEN` (Workers Scripts edit, Account Analytics read) and `CLOUDFLARE_ACCOUNT_ID`.

| Step | Detail |
| --- | --- |
| Deploy | `edge.mjs deploy`: `corpus/wrangler.edge.toml` (copy of `research/edge-bench/wrangler.toml`), the app of the `main` job, `js/` as `.roc-cfw/`. One version, no traffic split |
| Series | 100 `small` and 300 `mixed-ro` requests to `https://talon-registry-bench.bellup.workers.dev`, sequential, 60 ms apart. Free plan: 100,000 requests a day |
| Read | GraphQL `workersInvocationsAdaptive` filtered by `scriptName` and `scriptVersion`: `quantiles.cpuTimeP50`, `P90`, `P99` (microseconds). It polls for up to 20 minutes until 95 % of the requests are in |
| Rows | `where=edge`, scenario `edge-series`, source `analytics`: `cpu_p50_us`, `cpu_p90_us`, `cpu_p99_us`, `edge_requests` |

The quantiles are for all requests of the version, so p99 includes the first request of each isolate (the cold start). `node bench/perf/edge.mjs query` only reads (no deploy, no request): it was tested against the live account (read only). The edge rows are not a gate. They calibrate `budget.json` (`ins_per_ms`, `edge_share`): compare `cpu_p50_us` with the local `small` and `mixed-ro` rows of the same commit.
