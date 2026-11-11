# Ledger of the edge run (11c, conformance 0.0.9 and 0.0.10), 2026-11-11

Account: the account that wrangler is logged in to on this machine (Workers Paid), wrangler 4.151.0, OAuth login. workers.dev subdomain: `bellup`. The ledger of the run of 2026-10-17 is edge/ledger-2026-10-17.md.

Rule: each resource of this run has a name that starts with `rocplat-test-`. The run never changes a resource that is not in the table "Created" (`talon-registry*`, `talon-*index*` and `bellup-*` are not of this run).

## Start state (12:12 UTC, before the first create)

| Kind | Command | Items |
| --- | --- | --- |
| Workers | `wrangler deployments list --name <name>` | `rocplat-test-app`, `rocplat-test-echo`: none |
| D1 | `wrangler d1 list --json` | `talon-registry-bench-2`, `talon-registry-weur` (not of this run) |
| R2 | `wrangler r2 bucket list` | `bellup-weur-0`, `bellup-weur-0-preview`, `lottery0weur`, `rocplat-test-r2` (left by the 0.0.10 run of 2026-11-11 with incomplete multipart uploads; lifecycle rule `rocplat-test-abort`, 1 day) |
| KV | `wrangler kv namespace list` | the 2 `bellup-sveltekit-edge-*` namespaces |
| Queues | `wrangler queues list` | `talon-bench-index`, `talon-bench-index-dlq`, `talon-index`, `talon-index-dlq` (not of this run) |
| Workflows | `wrangler workflows list` | none |

## Created

| Time (UTC) | Kind | Name | Id | Deleted (UTC) |
| --- | --- | --- | --- | --- |
| before 12:12 | R2 | `rocplat-test-r2` | - (reused from the earlier run) | 13:05:04 |
| 12:38:42 | D1 | `rocplat-test-d1` | 764355ce-656c-497b-aa54-f6758331c9b8 | 13:04:54 |
| 12:38:49 | R2 | `rocplat-test-trace` | - | 13:05:07 |
| 12:38:51 | R2 lifecycle rule | `rocplat-test-abort` | on rocplat-test-trace: abort incomplete multipart uploads after 1 day (goes with the bucket) | with its bucket |
| 12:38:57 | Queue | `rocplat-test-jobs` | - | 13:04:28 |
| 12:38:59 | Queue | `rocplat-test-texts` | - | 13:04:32 |
| 12:39:02 | Queue | `rocplat-test-bin` | - | 13:04:35 |
| 12:39:06 | Queue | `rocplat-test-v8` | - | 13:04:39 |
| 12:39:08 | Queue | `rocplat-test-b64j` | - | 13:04:42 |
| 12:39:12 | Queue | `rocplat-test-decj` | - | 13:04:45 |
| 12:39:15 | Queue | `rocplat-test-decv` | - | 13:04:48 |
| 12:39:18 | Queue | `rocplat-test-decvjs` | - | 13:04:51 |
| 12:39:25 | KV | `rocplat-test-kv` | d93180f23a0d4bb2a6d3256b21088865 | 13:04:57 |
| 12:39:31 | KV | `rocplat-test-objflags` | df7f72c9aaca4079862fb213589fa795 | 13:05:01 |
| 12:39:48 | Worker | `rocplat-test-echo` | https://rocplat-test-echo.bellup.workers.dev | 13:04:21 |
| 12:41:47 | Workflow | `rocplat-test-flow` | made by the deploy of rocplat-test-app | 13:04:23 |
| 12:41:47 | Workflow | `rocplat-test-waiter` | made by the deploy of rocplat-test-app | 13:04:25 |
| 13:00:37 | Worker | `rocplat-test-echo` | https://rocplat-test-echo.bellup.workers.dev | 13:04:21 |
| 13:05:23 | D1 | `rocplat-test-d1` | d4079dc2-62e3-4bef-98f9-b7e572d37c5c | 13:17:30 |
| 13:05:27 | R2 | `rocplat-test-r2` | - | 13:17:41 |
| 13:05:30 | R2 lifecycle rule | `rocplat-test-abort` | on rocplat-test-r2: abort incomplete multipart uploads after 1 day (goes with the bucket) | with its bucket |
| 13:05:34 | R2 | `rocplat-test-trace` | - | 13:17:44 |
| 13:05:36 | R2 lifecycle rule | `rocplat-test-abort` | on rocplat-test-trace: abort incomplete multipart uploads after 1 day (goes with the bucket) | with its bucket |
| 13:05:42 | Queue | `rocplat-test-jobs` | - | 13:17:04 |
| 13:05:45 | Queue | `rocplat-test-texts` | - | 13:17:08 |
| 13:05:49 | Queue | `rocplat-test-bin` | - | 13:17:11 |
| 13:05:52 | Queue | `rocplat-test-v8` | - | 13:17:14 |
| 13:05:55 | Queue | `rocplat-test-b64j` | - | 13:17:18 |
| 13:05:59 | Queue | `rocplat-test-decj` | - | 13:17:21 |
| 13:06:03 | Queue | `rocplat-test-decv` | - | 13:17:24 |
| 13:06:06 | Queue | `rocplat-test-decvjs` | - | 13:17:28 |
| 13:06:13 | KV | `rocplat-test-kv` | 7a226efc61304035ba24bca7be1e5a3c | 13:17:34 |
| 13:06:20 | KV | `rocplat-test-objflags` | bf1d3c0b626d462fb4cfce6319edd059 | 13:17:38 |
| 13:06:38 | Worker | `rocplat-test-echo` | https://rocplat-test-echo.bellup.workers.dev | 13:16:54 |
| 13:07:21 | Worker | `rocplat-test-app` | https://rocplat-test-app.bellup.workers.dev (crons: "*/2 * * * *", "1-59/2 * * * *", "*/5 * * * *") | 13:16:51 |
| 13:17:50 | D1 | `rocplat-test-d1` | 24c5270c-2e27-4d59-883c-3f0417eb8b6c | 13:32:04 |
| 13:17:54 | R2 | `rocplat-test-r2` | - | 13:32:15 |
| 13:17:56 | R2 lifecycle rule | `rocplat-test-abort` | on rocplat-test-r2: abort incomplete multipart uploads after 1 day (goes with the bucket) | with its bucket |
| 13:18:00 | R2 | `rocplat-test-trace` | - | 13:32:17 |
| 13:18:02 | R2 lifecycle rule | `rocplat-test-abort` | on rocplat-test-trace: abort incomplete multipart uploads after 1 day (goes with the bucket) | with its bucket |
| 13:18:07 | Queue | `rocplat-test-jobs` | - | 13:31:38 |
| 13:18:10 | Queue | `rocplat-test-texts` | - | 13:31:41 |
| 13:18:13 | Queue | `rocplat-test-bin` | - | 13:31:45 |
| 13:18:16 | Queue | `rocplat-test-v8` | - | 13:31:48 |
| 13:18:20 | Queue | `rocplat-test-b64j` | - | 13:31:52 |
| 13:18:23 | Queue | `rocplat-test-decj` | - | 13:31:55 |
| 13:18:26 | Queue | `rocplat-test-decv` | - | 13:31:58 |
| 13:18:29 | Queue | `rocplat-test-decvjs` | - | 13:32:02 |
| 13:18:35 | KV | `rocplat-test-kv` | 185ed5801b914e539410d63e079001d3 | 13:32:08 |
| 13:18:43 | KV | `rocplat-test-objflags` | e3c373212d0f43d6a81623bf2e1812d2 | 13:32:12 |
| 13:19:00 | Worker | `rocplat-test-echo` | https://rocplat-test-echo.bellup.workers.dev | 13:31:31 |
| 13:19:44 | Worker | `rocplat-test-app` | https://rocplat-test-app.bellup.workers.dev (crons: "*/2 * * * *", "1-59/2 * * * *", "*/5 * * * *") | 13:31:28 |
| 13:32:23 | D1 | `rocplat-test-d1` | c4196e01-4fd3-446c-a1c4-9eadbc23c460 | 13:44:05 |
| 13:32:27 | R2 | `rocplat-test-r2` | - | 13:44:15 |
| 13:32:29 | R2 lifecycle rule | `rocplat-test-abort` | on rocplat-test-r2: abort incomplete multipart uploads after 1 day (goes with the bucket) | with its bucket |
| 13:32:33 | R2 | `rocplat-test-trace` | - | 13:44:17 |
| 13:32:35 | R2 lifecycle rule | `rocplat-test-abort` | on rocplat-test-trace: abort incomplete multipart uploads after 1 day (goes with the bucket) | with its bucket |
| 13:32:40 | Queue | `rocplat-test-jobs` | - | 13:43:39 |
| 13:32:44 | Queue | `rocplat-test-texts` | - | 13:43:43 |
| 13:32:47 | Queue | `rocplat-test-bin` | - | 13:43:46 |
| 13:32:50 | Queue | `rocplat-test-v8` | - | 13:43:49 |
| 13:32:52 | Queue | `rocplat-test-b64j` | - | 13:43:52 |
| 13:32:56 | Queue | `rocplat-test-decj` | - | 13:43:56 |
| 13:32:58 | Queue | `rocplat-test-decv` | - | 13:43:59 |
| 13:33:01 | Queue | `rocplat-test-decvjs` | - | 13:44:02 |
| 13:33:08 | KV | `rocplat-test-kv` | b85bd8ced24b4a36828fbddd8acdc1e5 | 13:44:09 |
| 13:33:14 | KV | `rocplat-test-objflags` | 1e535815041f46e4841cfbccb91c9671 | 13:44:13 |
| 13:33:32 | Worker | `rocplat-test-echo` | https://rocplat-test-echo.bellup.workers.dev | 13:43:33 |
| 13:34:13 | Worker | `rocplat-test-app` | https://rocplat-test-app.bellup.workers.dev (crons: "*/2 * * * *", "1-59/2 * * * *", "*/5 * * * *") | 13:43:30 |
| 13:44:24 | D1 | `rocplat-test-d1` | 285dac52-6b4b-455a-8c8c-2a02d8723402 | 13:53:52 |
| 13:44:28 | R2 | `rocplat-test-r2` | - | 13:54:01 |
| 13:44:30 | R2 lifecycle rule | `rocplat-test-abort` | on rocplat-test-r2: abort incomplete multipart uploads after 1 day (goes with the bucket) | with its bucket |
| 13:44:33 | R2 | `rocplat-test-trace` | - | 13:54:03 |
| 13:44:36 | R2 lifecycle rule | `rocplat-test-abort` | on rocplat-test-trace: abort incomplete multipart uploads after 1 day (goes with the bucket) | with its bucket |
| 13:44:40 | Queue | `rocplat-test-jobs` | - | 13:53:27 |
| 13:44:43 | Queue | `rocplat-test-texts` | - | 13:53:30 |
| 13:44:47 | Queue | `rocplat-test-bin` | - | 13:53:34 |
| 13:44:50 | Queue | `rocplat-test-v8` | - | 13:53:37 |
| 13:44:53 | Queue | `rocplat-test-b64j` | - | 13:53:40 |
| 13:44:56 | Queue | `rocplat-test-decj` | - | 13:53:43 |
| 13:44:58 | Queue | `rocplat-test-decv` | - | 13:53:46 |
| 13:45:02 | Queue | `rocplat-test-decvjs` | - | 13:53:49 |
| 13:45:12 | KV | `rocplat-test-kv` | bff058e188c04b34995299446c81d42b | 13:53:55 |
| 13:45:21 | KV | `rocplat-test-objflags` | d4f74362018c4261bbac74a0bfbe1576 | 13:53:59 |
| 13:45:40 | Worker | `rocplat-test-echo` | https://rocplat-test-echo.bellup.workers.dev | 13:53:21 |
| 13:46:30 | Worker | `rocplat-test-app` | https://rocplat-test-app.bellup.workers.dev (crons: "*/2 * * * *", "1-59/2 * * * *", "*/5 * * * *") | 13:53:17 |
| 13:54:11 | D1 | `rocplat-test-d1` | 21488d56-c598-4b8f-8d48-a2f115d69d1c | 14:03:57 |
| 13:54:14 | R2 | `rocplat-test-r2` | - | 14:04:07 |
| 13:54:17 | R2 lifecycle rule | `rocplat-test-abort` | on rocplat-test-r2: abort incomplete multipart uploads after 1 day (goes with the bucket) | with its bucket |
| 13:54:20 | R2 | `rocplat-test-trace` | - | 14:04:09 |
| 13:54:22 | R2 lifecycle rule | `rocplat-test-abort` | on rocplat-test-trace: abort incomplete multipart uploads after 1 day (goes with the bucket) | with its bucket |
| 13:54:28 | Queue | `rocplat-test-jobs` | - | 14:03:33 |
| 13:54:30 | Queue | `rocplat-test-texts` | - | 14:03:37 |
| 13:54:34 | Queue | `rocplat-test-bin` | - | 14:03:40 |
| 13:54:36 | Queue | `rocplat-test-v8` | - | 14:03:43 |
| 13:54:39 | Queue | `rocplat-test-b64j` | - | 14:03:46 |
| 13:54:42 | Queue | `rocplat-test-decj` | - | 14:03:49 |
| 13:54:45 | Queue | `rocplat-test-decv` | - | 14:03:52 |
| 13:54:48 | Queue | `rocplat-test-decvjs` | - | 14:03:55 |
| 13:54:54 | KV | `rocplat-test-kv` | d31bf3d236fd4157b5f9cc3d6c6e0de4 | 14:04:01 |
| 13:55:01 | KV | `rocplat-test-objflags` | 4d8b116f31b040b0b723d3637d7775ff | 14:04:05 |
| 13:55:18 | Worker | `rocplat-test-echo` | https://rocplat-test-echo.bellup.workers.dev | 14:03:28 |
| 13:56:00 | Worker | `rocplat-test-app` | https://rocplat-test-app.bellup.workers.dev (crons: "*/2 * * * *", "1-59/2 * * * *", "*/5 * * * *") | 14:03:25 |
| 14:04:15 | D1 | `rocplat-test-d1` | b95345d8-fc1c-4d16-b57a-c1583fe8d9e6 | 14:14:54 |
| 14:04:19 | R2 | `rocplat-test-r2` | - | 14:15:05 |
| 14:04:21 | R2 lifecycle rule | `rocplat-test-abort` | on rocplat-test-r2: abort incomplete multipart uploads after 1 day (goes with the bucket) | with its bucket |
| 14:04:25 | R2 | `rocplat-test-trace` | - | 14:15:07 |
| 14:04:27 | R2 lifecycle rule | `rocplat-test-abort` | on rocplat-test-trace: abort incomplete multipart uploads after 1 day (goes with the bucket) | with its bucket |
| 14:04:32 | Queue | `rocplat-test-jobs` | - | 14:14:29 |
| 14:04:34 | Queue | `rocplat-test-texts` | - | 14:14:32 |
| 14:04:37 | Queue | `rocplat-test-bin` | - | 14:14:35 |
| 14:04:40 | Queue | `rocplat-test-v8` | - | 14:14:38 |
| 14:04:44 | Queue | `rocplat-test-b64j` | - | 14:14:42 |
| 14:04:47 | Queue | `rocplat-test-decj` | - | 14:14:45 |
| 14:04:50 | Queue | `rocplat-test-decv` | - | 14:14:48 |
| 14:04:53 | Queue | `rocplat-test-decvjs` | - | 14:14:52 |
| 14:05:00 | KV | `rocplat-test-kv` | 3a66307d8d56417588450a305cdf747a | 14:14:58 |
| 14:05:07 | KV | `rocplat-test-objflags` | 7f18cd59f5974ebe96637698f516f306 | 14:15:02 |
| 14:05:24 | Worker | `rocplat-test-echo` | https://rocplat-test-echo.bellup.workers.dev | 14:14:23 |
| 14:06:07 | Worker | `rocplat-test-app` | https://rocplat-test-app.bellup.workers.dev (crons: "*/2 * * * *", "1-59/2 * * * *", "*/5 * * * *") | 14:14:20 |
| 14:15:14 | D1 | `rocplat-test-d1` | 7ff0847f-1192-46cf-a327-40f568477aa4 | 14:26:41 |
| 14:15:18 | R2 | `rocplat-test-r2` | - | 14:26:52 |
| 14:15:20 | R2 lifecycle rule | `rocplat-test-abort` | on rocplat-test-r2: abort incomplete multipart uploads after 1 day (goes with the bucket) | with its bucket |
| 14:15:24 | R2 | `rocplat-test-trace` | - | 14:26:54 |
| 14:15:26 | R2 lifecycle rule | `rocplat-test-abort` | on rocplat-test-trace: abort incomplete multipart uploads after 1 day (goes with the bucket) | with its bucket |
| 14:15:33 | Queue | `rocplat-test-jobs` | - | 14:26:16 |
| 14:15:36 | Queue | `rocplat-test-texts` | - | 14:26:19 |
| 14:15:39 | Queue | `rocplat-test-bin` | - | 14:26:23 |
| 14:15:43 | Queue | `rocplat-test-v8` | - | 14:26:26 |
| 14:15:46 | Queue | `rocplat-test-b64j` | - | 14:26:29 |
| 14:15:50 | Queue | `rocplat-test-decj` | - | 14:26:32 |
| 14:15:53 | Queue | `rocplat-test-decv` | - | 14:26:35 |
| 14:15:56 | Queue | `rocplat-test-decvjs` | - | 14:26:39 |
| 14:16:03 | KV | `rocplat-test-kv` | 4dad274d1ab74c46bb2cfb46cd6d9015 | 14:26:45 |
| 14:16:10 | KV | `rocplat-test-objflags` | 17ae08a9195c4d62a54adc1c0ac92a7c | 14:26:49 |
| 14:16:30 | Worker | `rocplat-test-echo` | https://rocplat-test-echo.bellup.workers.dev | 14:26:10 |
| 14:17:12 | Worker | `rocplat-test-app` | https://rocplat-test-app.bellup.workers.dev (crons: "*/2 * * * *", "1-59/2 * * * *", "*/5 * * * *") | 14:26:07 |
| 12:39 (first deploy) | Analytics Engine dataset | `rocplat_test_conformance` (binding `STATS`) | made by the first `writeDataPoint` | not deleted: Analytics Engine has no delete of a dataset; its data expires after 3 months. No cost on this plan |

## End state (14:27 UTC)

| Kind | Command | Items | Same as the start? |
| --- | --- | --- | --- |
| Workers | `wrangler deployments list --name <name>` | `rocplat-test-app`, `rocplat-test-echo`: none | Yes |
| D1 | `wrangler d1 list --json` | `talon-registry-bench-2`, `talon-registry-weur` | Yes |
| R2 | `wrangler r2 bucket list` | `bellup-weur-0`, `bellup-weur-0-preview`, `lottery0weur` | No: `rocplat-test-r2` (left by the earlier run) is also deleted now |
| KV | `wrangler kv namespace list` | the 2 `bellup-sveltekit-edge-*` namespaces | Yes |
| Queues | `wrangler queues list` | `talon-bench-index`, `talon-bench-index-dlq`, `talon-index`, `talon-index-dlq` (no `rocplat-test-` queue) | Yes |
| Workflows | `wrangler workflows list` | none ("There are no deployed Workflows in this account") | Yes |
| Durable Object namespaces, cron triggers | they belonged to `rocplat-test-app` | gone with the Worker | Yes |

Left: the Analytics Engine dataset `rocplat_test_conformance` (no delete command; see the table "Created").

The run made the resources 8 times (the first deploy at 12:38, then `edge/fresh-run.sh`, which deletes all and deploys again before each run, so each run starts with fresh bindings). The first deploy of the app failed once: the account refuses a KV-backed Durable Object class (code 10099), so the app has no `KVONLY`. Two runs were stopped early (a 0.0.10 run whose resources a started 0.0.9 cycle deleted, by a mistake of the operator); their results are not kept. Each `edge/deploy.sh delete` removed the queue consumers first, then the Workers, workflows, queues, D1, KV and the two buckets: no step failed. The two buckets were empty (`edge/wipe-r2.mjs`) and the delete took them, also with the multipart uploads that `mp_create` leaves open.
