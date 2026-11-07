SELECT an.value AS hash, a.kind AS kind, a.exposes AS exposed_json, pl.value AS platform_hash, a.roc_pin AS roc_pin, a.size AS size
FROM art a JOIN names an ON an.id = a.artifact LEFT JOIN names pl ON pl.id = a.platform ORDER BY an.value
