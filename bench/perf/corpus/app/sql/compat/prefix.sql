-- The bot set of R-MX11 (slices 115a and 115b): the CTE `members(artifact)`. It is the same condition as the trigger `sweeps_guard_insert` (sql/0002_triggers.sql).
-- ?1 the nightly id, ?2 the target code, ?3 the bound (a log index) or NULL = the log size now. The statement `missing` and the statement `members` are this text, a newline, and their file.
-- live: the releases at the bound that are not yanked and not withdrawn. members: a package or a platform; the newest of its form and series (the series is M, or 0.m for M = 0);
-- in the window of 548 days (47347200000 ms) before the first publish time of the nightly (the edge is in), or the newest live release of its form.
WITH
bound AS (SELECT COALESCE(CAST(?3 AS INTEGER), (SELECT COALESCE(MAX(idx), 0) FROM log)) AS upto),
live AS (SELECT r.* FROM releases r, bound WHERE r.log_index <= bound.upto AND r.yanked = 0 AND r.withdrawn IS NULL),
members AS (SELECT DISTINCT r.artifact FROM live r
    WHERE (SELECT a.kind FROM artifacts a WHERE a.artifact = r.artifact) IN (1, 2)
    AND NOT EXISTS (SELECT 1 FROM live r2 WHERE r2.form = r.form AND r2.version > r.version AND (r2.version >> 48) = (r.version >> 48)
        AND ((r.version >> 48) <> -32768 OR ((r2.version >> 32) & 65535) = ((r.version >> 32) & 65535)))
    AND (r.published_at >= (SELECT MIN(t.published_at) FROM toolchains t WHERE t.nightly = CAST(?1 AS INTEGER)) - 47347200000
        OR NOT EXISTS (SELECT 1 FROM live r3 WHERE r3.form = r.form AND r3.version > r.version)))
