-- R-AP4 (slice 115b): the hints of one artifact (?1), summed over talon_version. Order: the place of the nightly (R-MX16), the target name.
WITH d0 AS (SELECT nightly, MIN(tag) AS tag, MIN(published_at) AS t FROM toolchains GROUP BY nightly),
d AS MATERIALIZED (SELECT nightly, tag, ROW_NUMBER() OVER (ORDER BY nightly >> 28, t, nightly) AS ord FROM d0)
SELECT hn.value AS hash, d.tag AS nightly, tn.name AS target, SUM(x.pass_count) AS pass_count, SUM(x.fail_count) AS fail_count, SUM(x.crash_count) AS crash_count
FROM compat_hints x JOIN d ON d.nightly = x.nightly JOIN names hn ON hn.id = x.artifact JOIN targets tn ON tn.target = x.target
WHERE x.artifact = CAST(?1 AS INTEGER)
GROUP BY x.artifact, x.nightly, x.target ORDER BY d.ord, tn.name
