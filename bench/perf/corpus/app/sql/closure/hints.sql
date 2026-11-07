SELECT hn.value AS hash, d.tag AS nightly, tn.name AS target, SUM(x.pass_count) AS pass_count, SUM(x.fail_count) AS fail_count, SUM(x.crash_count) AS crash_count
FROM compat_hints x JOIN d ON d.nightly = x.nightly JOIN w ON d.ord BETWEEN w.lo AND w.hi JOIN names hn ON hn.id = x.artifact JOIN targets tn ON tn.target = x.target
WHERE x.artifact IN (SELECT artifact FROM art)
GROUP BY x.artifact, x.nightly, x.target ORDER BY hn.value, d.ord, tn.name
