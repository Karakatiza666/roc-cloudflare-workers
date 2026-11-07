## The pure part of the daily cron jobs (Registry R-CT5, R-CT15, R-PU35, R-PU36; slice 120, docs/slices/120-daily-crons.md).
## Every SQL text is a pure function of no value. W0 pins the key words, W2 (`worker/tests/cases/cron/`) pins what the text does on local D1.
## The order of the run is in `DailyCrons.run!`. Every body that is not a constant is a stub until the code agent writes it (TW18).
Daily :: [].{

	## The cron expression of the daily job (a proposal, TW24: 03:00 UTC). `wrangler.toml` `[triggers] crons` and `Worker.cron` in `main.roc` use the same text.
	cron : Str
	cron = "0 3 * * *"

	## 365 days in ms: a compiler is old when its smallest `published_at` is below now minus this (R-CT15, Design Q174). The same number as the `old-nightly` skip of R-CT14.
	old_ms : U64
	old_ms = 31_536_000_000

	## R-CT5, R-PU35 row "Hint cleanup", R-PU36: ONE `DELETE FROM compat_hints` of every row whose pair (artifact, nightly, target) has a `compat` row with `source` = 0 (`bot`).
	## All `talon_version` rows of the pair go. A `smoke` row (`source` 1) does not count. No parameter. The statement selects by state, so a second run finds no row.
	## It never touches `contributions` (they keep the history).
	hints_sql : () -> Str
	hints_sql = || "DELETE FROM compat_hints WHERE EXISTS (SELECT 1 FROM compat c WHERE c.artifact = compat_hints.artifact AND c.nightly = compat_hints.nightly AND c.target = compat_hints.target AND c.source = 0)"

	## R-RE6, R-RE24, R-PU35: ONE `DELETE FROM hint_days` of the rows older than 2 days. Parameter ?1: now (ms). The day is `?1 / 86400000` (days from 1970-01-01, UTC).
	## The row of today and of yesterday stay (the counter of R-CT13 must not restart). The edge (the row of today minus 2) is Design Q343 (slice file): no test until it is answered.
	days_sql : () -> Str
	days_sql = || "DELETE FROM hint_days WHERE day < ?1 / 86400000 - 2"

	## R-CT15, R-PU35 row "Trim": the compilers that are due. Parameter ?1: now (ms). One column `nightly` (text, `CAST(nightly AS TEXT)`: a 64-bit id travels as text).
	## A compiler is a `nightly` of `toolchains` (a nightly and a release, R-RE4). Due: the smallest `published_at` over its targets is below ?1 minus `old_ms` (an age of exactly 365 days is not old),
	## and it has a `contributions` row or a `compat_hints` row. Order: the smallest `published_at` first (the oldest first), then `nightly`.
	due_sql : () -> Str
	due_sql = || sql_text([
		"SELECT CAST(t.nightly AS TEXT) AS nightly FROM (SELECT nightly, MIN(published_at) AS oldest FROM toolchains GROUP BY nightly) t",
		"WHERE t.oldest < ?1 - 31536000000",
		"AND (EXISTS (SELECT 1 FROM contributions c WHERE c.nightly = t.nightly) OR EXISTS (SELECT 1 FROM compat_hints h WHERE h.nightly = t.nightly))",
		"ORDER BY t.oldest, t.nightly",
	])

	## R-CT15 steps 1 to 3, in this order, for ONE compiler. Parameter ?1 of each: the nightly as text (`CAST(?1 AS INTEGER)`). The three go in one `batch!` (D1 runs a batch in one transaction).
	## 1. Upsert `contributor_totals` for each contributor with `contributions` rows on that nightly: add the classes of R-CT10 (`counted`, `first`, `agreed`, `disagreed`, `unconfirmed`, as `Login.tracker_sql` counts them from the rows),
	##    `first_time` = the smaller and `last_time` = the larger of the row value and the `time` of these rows (Q302). `ON CONFLICT (contributor) DO UPDATE`, never `OR REPLACE`.
	##    It reads `contributions` and `compat`, so it runs before step 2 (the other rows of a pair are still there for `first`).
	## 2. `DELETE FROM contributions` of that nightly.
	## 3. `DELETE FROM compat_hints` of that nightly (also a row with no `bot` row).
	## It does not touch `compat` (R-CT15: the sweeps need the `bot` rows).
	trim_sqls : () -> List(Str)
	trim_sqls = || [totals_sql(), "DELETE FROM contributions WHERE nightly = CAST(?1 AS INTEGER)", "DELETE FROM compat_hints WHERE nightly = CAST(?1 AS INTEGER)"]

	## Step 1 of `trim_sqls`. The classes are the ones of `Login.tracker_sql`, here for the rows of one nightly.
	totals_sql : () -> Str
	totals_sql = || sql_text([
		"INSERT INTO contributor_totals (contributor, counted, first, agreed, disagreed, unconfirmed, first_time, last_time)",
		"SELECT contributor, COUNT(*), COALESCE(SUM(is_first), 0), COALESCE(SUM(bot IS NOT NULL AND bot = result), 0),",
		"COALESCE(SUM(bot IS NOT NULL AND bot <> result), 0), COALESCE(SUM(bot IS NULL), 0), MIN(seen), MAX(seen)",
		"FROM (SELECT m.contributor AS contributor, m.time AS seen, m.result AS result,",
		"(NOT EXISTS (SELECT 1 FROM compat x WHERE x.artifact = m.artifact AND x.nightly = m.nightly AND x.target = m.target AND x.time < m.time)",
		"AND NOT EXISTS (SELECT 1 FROM contributions o WHERE o.artifact = m.artifact AND o.nightly = m.nightly AND o.target = m.target AND o.contributor <> m.contributor",
		"AND (o.time < m.time OR (o.time = m.time AND o.contributor < m.contributor)))) AS is_first,",
		"(SELECT b.result FROM compat b WHERE b.artifact = m.artifact AND b.nightly = m.nightly AND b.target = m.target AND b.source = 0) AS bot",
		"FROM contributions m WHERE m.nightly = CAST(?1 AS INTEGER)) WHERE true GROUP BY contributor",
		"ON CONFLICT (contributor) DO UPDATE SET counted = contributor_totals.counted + excluded.counted, first = contributor_totals.first + excluded.first,",
		"agreed = contributor_totals.agreed + excluded.agreed, disagreed = contributor_totals.disagreed + excluded.disagreed,",
		"unconfirmed = contributor_totals.unconfirmed + excluded.unconfirmed,",
		"first_time = MIN(contributor_totals.first_time, excluded.first_time), last_time = MAX(contributor_totals.last_time, excluded.last_time)",
	])

	sql_text : List(Str) -> Str
	sql_text = |lines| Str.join_with(lines, " ")
}
