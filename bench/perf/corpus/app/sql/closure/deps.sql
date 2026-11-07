SELECT ow.value AS owner, dp.alias AS alias, dn.value AS hash, fn.value AS form, CAST(dp.version AS TEXT) AS version, dp.version_text AS version_text, dp.url AS url, dp.platform AS is_platform
FROM deps dp JOIN art a ON a.artifact = dp.artifact JOIN names ow ON ow.id = dp.artifact JOIN names dn ON dn.id = dp.dep LEFT JOIN names fn ON fn.id = dp.form
ORDER BY ow.value, dp.alias
