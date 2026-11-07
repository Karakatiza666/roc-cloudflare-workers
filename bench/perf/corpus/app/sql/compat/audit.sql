-- R-AP40 (slice 115b): the pairs (hash, nightly, target) that have hints and no bot row. ?1 the most pairs. Counts are sums over talon_version.
-- The nightly needs a toolchains row (it gives the tag). The target is any, or the artifact is a platform (R-MX13: no tool app target).
-- Order: the total (pass + fail + crash) from large to small, then the hash bytes, the nightly id, the target code (Q115b-6).
SELECT hn.value AS hash, tg.tag AS nightly, tn.name AS target, SUM(h.pass_count) AS pass_count, SUM(h.fail_count) AS fail_count, SUM(h.crash_count) AS crash_count
FROM compat_hints h
JOIN (SELECT nightly, MIN(tag) AS tag FROM toolchains GROUP BY nightly) tg ON tg.nightly = h.nightly
JOIN artifacts a ON a.artifact = h.artifact
JOIN names hn ON hn.id = h.artifact
JOIN targets tn ON tn.target = h.target
WHERE (h.target = 0 OR a.kind = 2)
AND NOT EXISTS (SELECT 1 FROM compat c WHERE c.artifact = h.artifact AND c.nightly = h.nightly AND c.target = h.target AND c.source = 0)
GROUP BY h.artifact, h.nightly, h.target
ORDER BY SUM(h.pass_count + h.fail_count + h.crash_count) DESC, hn.value, h.nightly, h.target
LIMIT CAST(?1 AS INTEGER)
