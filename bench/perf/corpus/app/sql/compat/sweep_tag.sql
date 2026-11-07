SELECT tag FROM toolchains WHERE nightly = CAST(?1 AS INTEGER) ORDER BY tag LIMIT 1
