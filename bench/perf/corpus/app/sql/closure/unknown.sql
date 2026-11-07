SELECT MIN(idx) AS idx FROM hx WHERE id NOT IN (SELECT artifact FROM artifacts) GROUP BY id ORDER BY idx
