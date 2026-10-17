# Ledger of the edge run (11c, 5d, 8g edge), 2026-10-17

Account: the account that wrangler is logged in to on this machine (Workers Free plan), wrangler 4.151.0, OAuth login. workers.dev subdomain: `bellup`.

Rule: each resource of this run has a name that starts with `rocplat-test-`. The run never changes a resource that is not in the table "Created".

## Start state (11:40 UTC, before the first create)

| Kind | Command | Items |
| --- | --- | --- |
| Workers | Workers API `GET /workers/scripts` (one read) | `bellup-sveltekit-edge` (modified 2023-05-15) |
| D1 | `wrangler d1 list --json` | none (`[]`) |
| R2 | `wrangler r2 bucket list` | `bellup-weur-0`, `bellup-weur-0-preview`, `lottery0weur` |
| KV | `wrangler kv namespace list` | `bellup-sveltekit-edge-bellup_kv_0` (`26d38271...`), `bellup-sveltekit-edge-bellup_kv_0_preview` (`5af50a5e...`) |
| Queues | `wrangler queues list` | none (empty output) |
| Workflows | `wrangler workflows list` | none |
| Vectorize | `wrangler vectorize list` | none |
| Hyperdrive | `wrangler hyperdrive list` | none |

## Created

| Time (UTC) | Kind | Name | Id | Deleted (UTC) |
| --- | --- | --- | --- | --- |
| 11:46:02 | D1 | `rocplat-test-d1` | 85ab4dbf-afaf-4807-b0b9-d44e5babfb18 | |
| 11:46:05 | R2 | `rocplat-test-r2` | - | |
| 11:46:10 | KV | `rocplat-test-kv` | f0de62f2176142b09b998909ad6cab12 | |
| 11:46:16 | KV | `rocplat-test-objflags` | d32b8ab5ef4c4aa5aaf12cfcf93b5183 | |
| 11:46:29 | Worker | `rocplat-test-echo` | https://rocplat-test-echo.bellup.workers.dev | |
| 11:46:53 | Worker | `rocplat-test-app` | https://rocplat-test-app.bellup.workers.dev (crons: "*/2 * * * *", "1-59/2 * * * *", "*/5 * * * *") | |
| 11:51:03 | D1 | `rocplat-test-8g-d1` | 433009f9-c954-4ed2-9fcd-5c42890197a8 | |
| 11:51:15 | Worker | `rocplat-test-8g` | https://rocplat-test-8g.bellup.workers.dev | |
| 11:54:15 | Queue | `rocplat-test-jobs` | 8d272d78f749480183154d3742a3651e | |
| 11:54:33 | Queue | `rocplat-test-texts` | 4ed79cc26c4449c6905634fc49a6296d | |
| 11:54:37 | Queue | `rocplat-test-bin` | 7a8f1a26e27c4c4d99e62b8df58f85b0 | |
| 11:54:41 | Queue | `rocplat-test-v8` | d125bbeace70441d9a455c01e2482454 | |
| 11:56:44 | Workflow | `rocplat-test-flow` | made by the deploy of rocplat-test-app | |
| 11:56:44 | Workflow | `rocplat-test-waiter` | made by the deploy of rocplat-test-app | |
| 12:31:53 | Worker | `rocplat-test-old` | https://rocplat-test-old.bellup.workers.dev (compatibility date 2025-06-01) | 12:32:07 |

## End state
