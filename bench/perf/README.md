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

Needs `perf` for the main metric (else `proc`; `PERF_SOURCE=vg` needs `valgrind` and `callgrind_control`), and the Miniflare of a global wrangler (`MINIFLARE=<dir>` otherwise). Node 26.

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
| `commit` | Short hash, `+dirty` when the tree has changes outside `bench/perf/results`, `research/`, `data/` (the checkout of `bench-data` in CI) and `base/` (the base of a PR in CI). `run.mjs` prints the files that make it dirty |
| `date`, `nightly` | UTC time, the Roc nightly of `compat/last-stack-first-nightly` |
| `label` | Free text (`--label`) |
| `where` | `local` (Miniflare, this bench) or `edge` (the real runtime, `edge.mjs`). A row with no `where` is `local` |
| `scenario` | A scenario name, or `static` |
| `metric`, `unit` | See below |
| `value` | Median of the rounds |
| `requests`, `rounds`, `min`, `max` | Measured requests, number of rounds, range of the rounds |
| `source` | `perf`, `vg`, `proc`, `stats` or `static` |

| Metric | Scenario | Source | Meaning |
| --- | --- | --- | --- |
| `ins_per_req` | each | perf | Instructions of workerd for each request. The main metric |
| `cold_first_ins` | small | perf | Instructions of the first request of a fresh isolate |
| `ir_per_req`, `cold_first_ir`, `cold_extra_ir` | small, each | vg | Same as the `ins_*` rows, but the Ir of valgrind (opt in, see "Without perf") |
| `cpu_min_ms_per_req` | each | proc | Smallest CPU time of the blocks of about 100 requests (whole scenario cycles). Information only: not tested on CI yet |
| `cross_per_req`, `xbytes_per_req` | each | stats | Calls across the JS/wasm boundary (`js_await`, `js_call`) and bytes of their programs and results, for each request. Exact |
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
| `alloc_bytes_per_req`, `cross_per_req`, `xbytes_per_req` | at most +2 %, +1 %, +2 % | Exact |
| `app_wasm_bytes` | at most +2 % | Exact |
| `largest_fn_bytes` | at most +5 % | Exact |
| `small` `ins_per_req` absolute | at most 1 ms of estimated edge CPU | 10 % of the limit. Now 0.48 ms |
| `closure`, `mixed-ro` absolute | at most 4 ms, 3 ms | 40 % and 30 % of the limit. Now 2.6 ms and 2.0 ms |
| `small` `cold_first_ins` absolute | at most 75 ms (target 10 ms, report only) | The first request of a fresh isolate is now 56 ms of the same unit, so the target of 10 ms is not met. The limit stops it from growing |

The estimate of edge ms: `instructions / calibration.ins_per_ms * edge_share`. `ins_per_ms` is 3.0 M (the dev machine: `small` is 3.6 M instructions and 1.1 to 1.2 ms of CPU). `edge_share` is 0.4 for the steady state (the user Worker is about 40 % of the workerd CPU, research/regprof/README.md) and 1 for the cold request. This is a guard rail in one unit, not a promise about the edge: confirm it with `wrangler tail` CPU times of the bench deployment (`worker/wrangler.bench.toml`) and change `ins_per_ms`. A new absolute value is a decision for the owner of the budget.

A relative rule needs a base from the same machine. The CI job builds the base and the head of the PR, runs both in turn 3 times on one runner, and compares the medians. A row of an older run on another machine is never a base.

## Without perf

A hosted GitHub runner is a VM with no hardware counters. Measured on `ubuntu-24.04` (AMD EPYC 7763), run 42386276899: `perf stat -e instructions` and `-e instructions:u` give "not supported" (also with `perf_event_paranoid=-1`). The other `perf` events there are software events (`cpu-clock`, `task-clock`, `page-faults`), and they are time or count of events, not instructions. So the CI rows have the source `proc` (CPU ms of workerd, now from the ns counter of `schedstat`), and the base and the head run in turn on one runner.

Options for a stable CPU value without counters (A/A: the same `app.wasm` in each run):

| Option | Runtime | Noise (A/A) | Result |
| --- | --- | --- | --- |
| perf software events | 0 | Same as `proc` (time based) | No gain |
| `proc` CPU ms, CI, 5 runs in turn | 1 min each | CV 6.4 to 8.5 %, range 15 to 20 % (a rise from run 1 to run 5) | Gate with thresholds times 4, base and head in turn |
| `proc` CPU ms, dev machine under load | 1 min each | Range 180 to 290 % | Not usable on a loaded machine |
| valgrind callgrind on workerd (`PERF_SOURCE=vg`) | 3 to 6 min for each round (about 30 ms for each request, 100 s start, 15 to 25 times slower) | Ir of the event-loop thread: CV 0.6 % in one run, but 2 states between runs: 3.58 M and 4.5 to 4.6 M for each request (+26 %), 5 of 7 runs in the high state. One CI round failed with `ECONNRESET` | Opt in only, not a gate |
| Exact counters (`allocs_per_req`, `alloc_bytes_per_req`, `cross_per_req`, `xbytes_per_req`, sizes) | 0 | 0 % | Gate with small thresholds in all modes |

Valgrind runs workerd and the V8 JIT with no flags (valgrind 3.22 on CI, 3.26 on the dev machine; `MINIFLARE_WORKERD_PATH` is a wrapper script). The metric is the busiest thread of `--separate-threads=yes`: it has 98 % of the Ir, the helper threads (GC, wasm compile) vary by 5 to 15 %. The Ir of the low state is equal to the perf value (3.58 M against 3.59 M for `small`), so the low state is the right one. The jump follows the tier-up state of the wasm in V8, and the bench cannot set V8 flags in workerd. A gate would need many rounds and a minimum, which costs more than the PR job can use.

The exact counters follow the CPU only in part. Over the 6 scenarios `ins_per_req` is about 11 k instructions for each allocation (residual 5 to 16 %), so `allocs_per_req` shows an allocation-heavy change, but not a codegen or host change. `cross_per_req` is 1.5 for `small`: the boundary is not the CPU cost, so it is a guard for the number of crossings only.

| Source | Gate in the PR job |
| --- | --- |
| `perf` (counters) | Instructions: `small` +3 %, other scenarios +5 %, plus the absolute rules |
| `proc` (no counters) | CPU ms with the thresholds times `proc_factor` (4): `small` +12 %, other scenarios +20 %; no absolute rules |
| `vg` (opt in) | Ir with the thresholds times `vg_factor` (10); absolute rules with `ir_per_ms` |
| all | Exact counters and sizes (table "Budget"), the same small thresholds |

Rows of different sources are never compared: `check.mjs` stops with exit 2 when the head and the base have different sources, and `chart.mjs` draws `perf` rows and `vg` rows in separate charts.

| Metric | Comparable between runs on different machines | Between the base and the head of one job |
| --- | --- | --- |
| `ins_per_req` (perf) | Only on the same CPU type | Yes |
| `cpu_ms_per_req` (proc) | No | Yes, with wide thresholds |
| `ir_per_req` (vg) | Yes (user code only), but with the 26 % jump | No |
| `allocs_per_req`, `cross_per_req`, `mem_peak_bytes`, sizes | Yes | Yes |

## Edge CPU (optional, after a merge)

The `edge` job of `perf.yml` runs only on a push to main, and only when the repository variable `PERF_EDGE` is `true`. It needs the secrets `CLOUDFLARE_API_TOKEN` (Workers Scripts edit, Account Analytics read) and `CLOUDFLARE_ACCOUNT_ID`.

| Step | Detail |
| --- | --- |
| Deploy | `edge.mjs deploy`: `corpus/wrangler.edge.toml` (copy of `research/edge-bench/wrangler.toml`), the app of the `main` job, `js/` as `.roc-cfw/`. One version, no traffic split |
| Series | 100 `small` and 300 `mixed-ro` requests to `https://talon-registry-bench.bellup.workers.dev`, sequential, 60 ms apart. Free plan: 100,000 requests a day |
| Read | GraphQL `workersInvocationsAdaptive` filtered by `scriptName` and `scriptVersion`: `quantiles.cpuTimeP50`, `P90`, `P99` (microseconds). It polls for up to 20 minutes until 95 % of the requests are in |
| Rows | `where=edge`, scenario `edge-series`, source `analytics`: `cpu_p50_us`, `cpu_p90_us`, `cpu_p99_us`, `edge_requests` |

The quantiles are for all requests of the version, so p99 includes the first request of each isolate (the cold start). `node bench/perf/edge.mjs query` only reads (no deploy, no request): it was tested against the live account (read only). The edge rows are not a gate. They calibrate `budget.json` (`ins_per_ms`, `edge_share`): compare `cpu_p50_us` with the local `small` and `mixed-ro` rows of the same commit.
