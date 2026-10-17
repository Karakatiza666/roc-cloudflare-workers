#!/usr/bin/env bash
# PLAN.md 11c, API.md AQ12: the rows of the cron test (edge/EdgeRoutes.roc `scheduled!`), and the count of runs for each
# cron and `time_ms`. Usage: edge/cron-rows.sh [database] (default rocplat-test-d1)
set -euo pipefail
wrangler d1 execute "${1:-rocplat-test-d1}" --remote --json --command "SELECT cron, time_ms, count(*) AS runs, min(run_ms - time_ms) AS first_delay_ms, max(run_ms - time_ms) AS last_delay_ms FROM cron_runs GROUP BY cron, time_ms ORDER BY time_ms, cron" 2>/dev/null |
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{for(const r of JSON.parse(s)[0].results)console.log([r.cron.padEnd(15),new Date(r.time_ms).toISOString(),"runs="+r.runs,"delay_ms="+r.first_delay_ms+".."+r.last_delay_ms].join("  "))})'
