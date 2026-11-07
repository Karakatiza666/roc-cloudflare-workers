, m AS (SELECT c.artifact, c.target, c.source, c.result, c.error_digest, d.ord, CASE WHEN d.ord < e.lo THEN 'before' ELSE 'after' END AS side
    FROM compat c JOIN d ON d.nightly = c.nightly JOIN e ON e.target = c.target
    WHERE c.artifact IN (SELECT artifact FROM art) AND (d.ord < e.lo OR d.ord > e.hi)
    AND NOT (c.source = 1 AND EXISTS (SELECT 1 FROM compat b WHERE b.artifact = c.artifact AND b.nightly = c.nightly AND b.target = c.target AND b.source = 0))),
k AS (SELECT m.*, ROW_NUMBER() OVER (PARTITION BY artifact, target, side ORDER BY CASE side WHEN 'before' THEN -ord ELSE ord END) AS n
    FROM m WHERE result IN (0, 1))
SELECT hn.value AS hash, tn.name AS target, k.source AS source, k.result AS result, k.error_digest AS error_digest, dn.tag AS nightly, k.side AS side
FROM k JOIN d dn ON dn.ord = k.ord JOIN names hn ON hn.id = k.artifact JOIN targets tn ON tn.target = k.target
WHERE k.n = 1 ORDER BY hn.value, tn.name, k.side DESC
