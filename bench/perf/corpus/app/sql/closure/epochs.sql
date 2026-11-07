SELECT tn.name AS target, a.tag AS "from", b.tag AS "to"
FROM (SELECT ep.target, MIN(ep.ord) AS lo, MAX(ep.ord) AS hi FROM ep JOIN e ON e.target = ep.target WHERE ep.ord BETWEEN e.lo AND e.hi
    GROUP BY ep.target, ep.epoch HAVING COUNT(*) > 1) x
JOIN d a ON a.ord = x.lo JOIN d b ON b.ord = x.hi JOIN targets tn ON tn.target = x.target ORDER BY tn.name, x.lo
