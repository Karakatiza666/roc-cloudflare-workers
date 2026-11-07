-- The closure query (Registry R-AP16 to R-AP18, slice 110): the CTEs of the 12 statements. Each statement is this text, a newline, and its file.
-- ?1 the groups [{form, lo, hi}], ?2 the artifact ids, ?3 and ?4 the nightly ids of the window ends or NULL (docs/slices/110-closure.md section 4).
-- grp: the groups. hx: the ids of ?2 with their 0-based index. cl: the closure (R-RE19), UNION so that a cycle ends. art: the ids of cl with an artifacts row.
-- d: the compilers in the order of R-MX16 (the date, then t, then the id). ep: the epoch number of each compiler on each target (R-MX12).
-- w: the places of the window ends (R-AP60, R-AP61). e: the window made larger to the ends of each epoch that it touches. r: the compat rows in e.
WITH RECURSIVE
grp AS (SELECT CAST(json_extract(g.value, '$.form') AS INTEGER) AS form, CAST(json_extract(g.value, '$.lo') AS INTEGER) AS lo,
    CAST(json_extract(g.value, '$.hi') AS INTEGER) AS hi FROM json_each(?1) g),
hx AS (SELECT CAST(h.key AS INTEGER) AS idx, h.value AS id FROM json_each(?2) h),
cl(id) AS (SELECT r.artifact FROM releases r JOIN grp g ON r.form = g.form AND r.version BETWEEN g.lo AND g.hi
    UNION SELECT id FROM hx
    UNION SELECT dp.dep FROM deps dp JOIN cl ON dp.artifact = cl.id),
art AS (SELECT a.* FROM artifacts a WHERE a.artifact IN (SELECT id FROM cl)),
d0 AS (SELECT nightly, MIN(tag) AS tag, MIN(published_at) AS t FROM toolchains GROUP BY nightly),
d AS MATERIALIZED (SELECT nightly, tag, ROW_NUMBER() OVER (ORDER BY nightly >> 28, t, nightly) AS ord,
    LAG(nightly) OVER (ORDER BY nightly >> 28, t, nightly) AS prev FROM d0),
tg AS (SELECT DISTINCT target FROM compat WHERE artifact IN (SELECT artifact FROM art)),
ep AS MATERIALIZED (SELECT t.target, d.nightly, d.ord, SUM(CASE WHEN EXISTS (SELECT 1 FROM transitions x
    WHERE x.nightly = d.nightly AND x.target = t.target AND x.previous = d.prev AND x.changed = 0) THEN 0 ELSE 1 END)
    OVER (PARTITION BY t.target ORDER BY d.ord) AS epoch FROM d, tg t),
w AS (SELECT COALESCE((SELECT ord FROM d WHERE nightly = CAST(?3 AS INTEGER)), 1) AS lo,
    COALESCE((SELECT ord FROM d WHERE nightly = CAST(?4 AS INTEGER)), (SELECT MAX(ord) FROM d)) AS hi),
e AS (SELECT ep.target, MIN(ep.ord) AS lo, MAX(ep.ord) AS hi
    FROM ep JOIN (SELECT target, MIN(epoch) AS e0, MAX(epoch) AS e1 FROM ep, w WHERE ord BETWEEN w.lo AND w.hi GROUP BY target) z
    ON z.target = ep.target WHERE ep.epoch BETWEEN z.e0 AND z.e1 GROUP BY ep.target),
r AS (SELECT c.artifact, c.target, c.source, c.result, c.error_digest, d.ord FROM compat c JOIN d ON d.nightly = c.nightly
    JOIN e ON e.target = c.target WHERE c.artifact IN (SELECT artifact FROM art) AND d.ord BETWEEN e.lo AND e.hi),
rel AS (SELECT * FROM releases WHERE artifact IN (SELECT artifact FROM art))
