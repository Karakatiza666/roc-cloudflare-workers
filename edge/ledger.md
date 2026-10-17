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
| 11:46:02 | D1 | `rocplat-test-d1` | 85ab4dbf-afaf-4807-b0b9-d44e5babfb18 | 12:58:44 |
| 11:46:05 | R2 | `rocplat-test-r2` | - | not yet: empty of objects, held by incomplete multipart uploads (End state) |
| 11:46:10 | KV | `rocplat-test-kv` | f0de62f2176142b09b998909ad6cab12 | 12:59:01 |
| 11:46:16 | KV | `rocplat-test-objflags` | d32b8ab5ef4c4aa5aaf12cfcf93b5183 | 12:59:03 |
| 11:46:29 | Worker | `rocplat-test-echo` | https://rocplat-test-echo.bellup.workers.dev | 12:58:42 |
| 11:46:53 | Worker | `rocplat-test-app` | https://rocplat-test-app.bellup.workers.dev (crons: "*/2 * * * *", "1-59/2 * * * *", "*/5 * * * *") | 12:59:31 |
| 11:46:53 | Durable Object namespaces | `rocplat-test-app` classes Counter, Store, Flaky, Slow, Ticker, Room (SQLite) | made by the deploy of the Worker; they go with it | 12:59:31 (with the Worker) |
| 11:51:03 | D1 | `rocplat-test-8g-d1` | 433009f9-c954-4ed2-9fcd-5c42890197a8 | 12:59:07 |
| 11:51:15 | Worker | `rocplat-test-8g` | https://rocplat-test-8g.bellup.workers.dev | 12:59:05 |
| 11:54:15 | Queue | `rocplat-test-jobs` | 8d272d78f749480183154d3742a3651e | 12:59:34 |
| 11:54:33 | Queue | `rocplat-test-texts` | 4ed79cc26c4449c6905634fc49a6296d | 12:59:36 |
| 11:54:37 | Queue | `rocplat-test-bin` | 7a8f1a26e27c4c4d99e62b8df58f85b0 | 12:59:39 |
| 11:54:41 | Queue | `rocplat-test-v8` | d125bbeace70441d9a455c01e2482454 | 12:59:41 |
| 11:56:44 | Workflow | `rocplat-test-flow` | made by the deploy of rocplat-test-app | 12:58:47 |
| 11:56:44 | Workflow | `rocplat-test-waiter` | made by the deploy of rocplat-test-app | 12:58:48 |
| 12:31:53 | Worker | `rocplat-test-old` | https://rocplat-test-old.bellup.workers.dev (compatibility date 2025-06-01) | 12:32:07 |
| 12:31:53 | Durable Object namespace | `rocplat-test-old` class Counter (SQLite) | made by the deploy of the Worker; it went with it | 12:32:07 |
| 13:02:30 | R2 lifecycle rule | `rocplat-test-abort` on `rocplat-test-r2` | abort incomplete multipart uploads after 1 day | goes with the bucket |

## End state (13:03 UTC)

| Kind | Command | Items | Same as the start? |
| --- | --- | --- | --- |
| Workers | `wrangler deployments list --name <name>` for each name of this run, and for `bellup-sveltekit-edge` | `rocplat-test-app`, `-echo`, `-8g`, `-old`: gone. `bellup-sveltekit-edge`: there | Yes |
| D1 | `wrangler d1 list --json` | `[]` | Yes |
| R2 | `wrangler r2 bucket list` | `bellup-weur-0`, `bellup-weur-0-preview`, `lottery0weur`, and `rocplat-test-r2` | No: see below |
| KV | `wrangler kv namespace list` | the 2 `bellup-sveltekit-edge-*` namespaces | Yes |
| Queues | `wrangler queues list` | no `rocplat-test-` queue (empty, as at the start) | Yes |
| Workflows | `wrangler workflows list` | none | Yes |
| Cron triggers | they belonged to `rocplat-test-app` | gone with the Worker (12:59:31) | Yes |

Open: the bucket `rocplat-test-r2` has no object (all 22 keys deleted at 12:58 and 13:00, `wrangler r2 object get rocplat-test-r2/big` gives "The specified key does not exist"), but `wrangler r2 bucket delete` refuses it: "The bucket you tried to delete (rocplat-test-r2) is not empty [code: 10008]". The cause is the incomplete multipart uploads of the conformance checks (`mp_create`, `mp_part_with`: their upload ids are not kept, and the R2 binding cannot list uploads). At 13:02 the run added the lifecycle rule `rocplat-test-abort` ("Abort incomplete multipart uploads after 1 days") to this bucket only. After 2026-10-18 13:02 UTC run:

```sh
wrangler r2 bucket delete rocplat-test-r2
```

Raw lists: `edge/.start-lists.txt` (start) and `edge/.end-lists.txt` (end).
