SELECT r.log_index AS log_index, an.value AS hash, fn.value AS form, CAST(r.version AS TEXT) AS version, r.version_text AS version_text, r.url AS url,
    r.tag AS tag, r.roc_version AS roc_version, rn.value AS repo, r.published_at AS published_at, r.yanked AS yanked, r.withdrawn AS withdrawn,
    (SELECT group_concat(via) FROM (SELECT via FROM provenance WHERE release = r.log_index ORDER BY via)) AS vias
FROM rel r JOIN names an ON an.id = r.artifact JOIN names fn ON fn.id = r.form LEFT JOIN names rn ON rn.id = r.repo ORDER BY r.log_index
