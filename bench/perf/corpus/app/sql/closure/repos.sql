SELECT rn.value AS name, p.state AS state, sn.value AS successor, p.state_at AS state_at
FROM repos p JOIN names rn ON rn.id = p.repo LEFT JOIN names sn ON sn.id = p.successor
WHERE p.repo IN (SELECT repo FROM rel) ORDER BY rn.value
