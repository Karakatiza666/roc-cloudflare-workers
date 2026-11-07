SELECT rn.value AS name, c.checked_at AS checked_at, COALESCE(c.app_installed, 0) AS app_installed
FROM (SELECT DISTINCT repo FROM releases WHERE form IN (SELECT form FROM grp) AND repo IS NOT NULL) p
JOIN names rn ON rn.id = p.repo LEFT JOIN repo_checks c ON c.repo = p.repo ORDER BY rn.value
