SELECT ow.value AS owner, t.name AS name FROM artifact_targets x JOIN art a ON a.artifact = x.artifact JOIN names ow ON ow.id = x.artifact
JOIN targets t ON t.target = x.target ORDER BY ow.value, t.name
