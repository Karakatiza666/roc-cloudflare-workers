-- Registry triggers, P2 (slice 103). Registry R-MX8, R-MX12, R-RE8, R-RE23, R-CT13, R-SG8, Design Q27, Q79 to Q86.
-- One statement for each semicolon (a trigger body is BEGIN ... END followed by a semicolon).
-- No PRAGMA and no explicit transaction statement (wrangler refuses a local file that has that text, even in a comment): D1 and node:sqlite take the same file.
-- There is no trigger that writes a leaf. The Worker writes the leaf (R-SG8). A trigger only checks it.
-- The member condition of R-MX11 is a correlated NOT EXISTS: SQLite allows no WITH clause in a trigger.
-- Codes (R-IK7): artifact kind app 0, package 1, platform 2. Source bot 0. Result pass 0, fail 1, hang 2, crash 3.
-- Times are in ms. 47347200000 ms is 548 days (R-MX11 row 3). 86400000 ms is one day.

-- Q27, R-SG8 row 4: a label keeps its first artifact. The same label with the same artifact is no conflict.
-- A BEFORE trigger on purpose: it must fire also for INSERT OR IGNORE.
CREATE TRIGGER releases_label_conflict BEFORE INSERT ON releases
BEGIN
  SELECT RAISE(ABORT, 'label-conflict') WHERE EXISTS (
    SELECT 1 FROM releases
    WHERE form = NEW.form AND version = NEW.version AND version_text = NEW.version_text AND artifact <> NEW.artifact);
END;

-- R-SG8 row 5: an AFTER trigger. A skipped insert fires none, so a publish that is sent again passes.
CREATE TRIGGER releases_leaf_check AFTER INSERT ON releases
BEGIN
  SELECT RAISE(ABORT, 'leaf-missing') WHERE NOT EXISTS (
    SELECT 1 FROM log
    WHERE idx = NEW.log_index AND grp = (SELECT value FROM names WHERE id = NEW.form AND kind = 2));
END;

CREATE TRIGGER toolchains_leaf_check AFTER INSERT ON toolchains
BEGIN
  SELECT RAISE(ABORT, 'leaf-missing') WHERE NOT EXISTS (
    SELECT 1 FROM log
    WHERE idx = NEW.log_index AND grp = 'roc-lang/nightlies:' || NEW.target
      AND version = NEW.tag AND hash = 'sha256:' || NEW.sha256);
END;

-- R-MX8, Q83: the insert guard checks nothing when the row of (nightly, target) has a bound at least the new bound.
-- R-MX11: r is a member of the bot set at bound NEW.upto_log_index for nightly NEW.nightly when
--   1 r is live: log_index within the bound, not yanked, not withdrawn,
--   2 r is a package or a platform,
--   3 no live release of the same form and series has a larger version,
--   4 r is in the window (t is MIN(published_at) of the nightly in toolchains) or r is the newest live release of its form.
-- The series: the same major, and for major 0 the same minor (major 0 is stored >> 48 = -32768).
CREATE TRIGGER sweeps_guard_insert BEFORE INSERT ON sweeps
WHEN NOT EXISTS (
  SELECT 1 FROM sweeps s
  WHERE s.nightly = NEW.nightly AND s.target = NEW.target AND s.upto_log_index >= NEW.upto_log_index)
BEGIN
  SELECT RAISE(ABORT, 'sweep-bound') WHERE NEW.upto_log_index > (SELECT COALESCE(MAX(idx), 0) FROM log);
  SELECT RAISE(ABORT, 'sweep-incomplete') WHERE EXISTS (
    SELECT 1 FROM releases r
    WHERE r.log_index <= NEW.upto_log_index AND r.yanked = 0 AND r.withdrawn IS NULL
      AND (SELECT a.kind FROM artifacts a WHERE a.artifact = r.artifact) IN (1, 2)
      AND NOT EXISTS (
        SELECT 1 FROM releases r2
        WHERE r2.form = r.form AND r2.log_index <= NEW.upto_log_index AND r2.yanked = 0 AND r2.withdrawn IS NULL
          AND r2.version > r.version AND (r2.version >> 48) = (r.version >> 48)
          AND ((r.version >> 48) <> -32768 OR ((r2.version >> 32) & 65535) = ((r.version >> 32) & 65535)))
      AND (
        r.published_at >= (SELECT MIN(t.published_at) FROM toolchains t WHERE t.nightly = NEW.nightly) - 47347200000
        OR NOT EXISTS (
          SELECT 1 FROM releases r3
          WHERE r3.form = r.form AND r3.log_index <= NEW.upto_log_index AND r3.yanked = 0 AND r3.withdrawn IS NULL
            AND r3.version > r.version))
      AND NOT EXISTS (
        SELECT 1 FROM compat c
        WHERE c.artifact = r.artifact AND c.nightly = NEW.nightly AND c.target = NEW.target AND c.source = 0));
END;

-- The update trigger has no skip. R-RE6: a sweep never makes a bound smaller.
CREATE TRIGGER sweeps_guard_update BEFORE UPDATE ON sweeps
BEGIN
  SELECT RAISE(ABORT, 'sweep-smaller') WHERE NEW.upto_log_index < OLD.upto_log_index;
  SELECT RAISE(ABORT, 'sweep-bound') WHERE NEW.upto_log_index > (SELECT COALESCE(MAX(idx), 0) FROM log);
  SELECT RAISE(ABORT, 'sweep-incomplete') WHERE EXISTS (
    SELECT 1 FROM releases r
    WHERE r.log_index <= NEW.upto_log_index AND r.yanked = 0 AND r.withdrawn IS NULL
      AND (SELECT a.kind FROM artifacts a WHERE a.artifact = r.artifact) IN (1, 2)
      AND NOT EXISTS (
        SELECT 1 FROM releases r2
        WHERE r2.form = r.form AND r2.log_index <= NEW.upto_log_index AND r2.yanked = 0 AND r2.withdrawn IS NULL
          AND r2.version > r.version AND (r2.version >> 48) = (r.version >> 48)
          AND ((r.version >> 48) <> -32768 OR ((r2.version >> 32) & 65535) = ((r.version >> 32) & 65535)))
      AND (
        r.published_at >= (SELECT MIN(t.published_at) FROM toolchains t WHERE t.nightly = NEW.nightly) - 47347200000
        OR NOT EXISTS (
          SELECT 1 FROM releases r3
          WHERE r3.form = r.form AND r3.log_index <= NEW.upto_log_index AND r3.yanked = 0 AND r3.withdrawn IS NULL
            AND r3.version > r.version))
      AND NOT EXISTS (
        SELECT 1 FROM compat c
        WHERE c.artifact = r.artifact AND c.nightly = NEW.nightly AND c.target = NEW.target AND c.source = 0));
END;

-- R-MX12, R-RE23, R-MX16: a transitions row for the swept nightly and each adjacent nightly that is swept on the same target.
-- The order is over the distinct nightlies: the date (nightly >> 28), then t, then the id. A nightly with no
-- toolchains row has no t, so it has no row. The row has the key of the later nightly.
-- compared counts the hashes with a bot result in (pass, fail) on both nightlies, changed those with another result.
-- ON CONFLICT DO UPDATE and not INSERT OR REPLACE (Q84, slice 103 F1).
CREATE TRIGGER sweeps_transitions_insert AFTER INSERT ON sweeps
BEGIN
  INSERT INTO transitions (nightly, target, previous, compared, changed)
  SELECT NEW.nightly, NEW.target, p.nightly,
    (SELECT COUNT(*) FROM compat a JOIN compat b
       ON b.artifact = a.artifact AND b.nightly = NEW.nightly AND b.target = a.target AND b.source = 0 AND b.result IN (0, 1)
     WHERE a.nightly = p.nightly AND a.target = NEW.target AND a.source = 0 AND a.result IN (0, 1)),
    (SELECT COUNT(*) FROM compat a JOIN compat b
       ON b.artifact = a.artifact AND b.nightly = NEW.nightly AND b.target = a.target AND b.source = 0 AND b.result IN (0, 1)
     WHERE a.nightly = p.nightly AND a.target = NEW.target AND a.source = 0 AND a.result IN (0, 1) AND a.result <> b.result)
  FROM (
    SELECT (SELECT x.nightly FROM (SELECT nightly, MIN(published_at) AS t FROM toolchains GROUP BY nightly) x
      WHERE (x.nightly >> 28) < (NEW.nightly >> 28)
        OR ((x.nightly >> 28) = (NEW.nightly >> 28) AND x.t < (SELECT MIN(published_at) FROM toolchains WHERE nightly = NEW.nightly))
        OR ((x.nightly >> 28) = (NEW.nightly >> 28) AND x.t = (SELECT MIN(published_at) FROM toolchains WHERE nightly = NEW.nightly)
            AND x.nightly < NEW.nightly)
      ORDER BY (x.nightly >> 28) DESC, x.t DESC, x.nightly DESC LIMIT 1) AS nightly
    WHERE EXISTS (SELECT 1 FROM toolchains WHERE nightly = NEW.nightly)) p
  WHERE p.nightly IS NOT NULL AND EXISTS (SELECT 1 FROM sweeps s WHERE s.nightly = p.nightly AND s.target = NEW.target)
  ON CONFLICT (nightly, target) DO UPDATE SET
    previous = excluded.previous, compared = excluded.compared, changed = excluded.changed;
  INSERT INTO transitions (nightly, target, previous, compared, changed)
  SELECT q.nightly, NEW.target, NEW.nightly,
    (SELECT COUNT(*) FROM compat a JOIN compat b
       ON b.artifact = a.artifact AND b.nightly = q.nightly AND b.target = a.target AND b.source = 0 AND b.result IN (0, 1)
     WHERE a.nightly = NEW.nightly AND a.target = NEW.target AND a.source = 0 AND a.result IN (0, 1)),
    (SELECT COUNT(*) FROM compat a JOIN compat b
       ON b.artifact = a.artifact AND b.nightly = q.nightly AND b.target = a.target AND b.source = 0 AND b.result IN (0, 1)
     WHERE a.nightly = NEW.nightly AND a.target = NEW.target AND a.source = 0 AND a.result IN (0, 1) AND a.result <> b.result)
  FROM (
    SELECT (SELECT x.nightly FROM (SELECT nightly, MIN(published_at) AS t FROM toolchains GROUP BY nightly) x
      WHERE (x.nightly >> 28) > (NEW.nightly >> 28)
        OR ((x.nightly >> 28) = (NEW.nightly >> 28) AND x.t > (SELECT MIN(published_at) FROM toolchains WHERE nightly = NEW.nightly))
        OR ((x.nightly >> 28) = (NEW.nightly >> 28) AND x.t = (SELECT MIN(published_at) FROM toolchains WHERE nightly = NEW.nightly)
            AND x.nightly > NEW.nightly)
      ORDER BY (x.nightly >> 28), x.t, x.nightly LIMIT 1) AS nightly
    WHERE EXISTS (SELECT 1 FROM toolchains WHERE nightly = NEW.nightly)) q
  WHERE q.nightly IS NOT NULL AND EXISTS (SELECT 1 FROM sweeps s WHERE s.nightly = q.nightly AND s.target = NEW.target)
  ON CONFLICT (nightly, target) DO UPDATE SET
    previous = excluded.previous, compared = excluded.compared, changed = excluded.changed;
END;

CREATE TRIGGER sweeps_transitions_update AFTER UPDATE ON sweeps
BEGIN
  INSERT INTO transitions (nightly, target, previous, compared, changed)
  SELECT NEW.nightly, NEW.target, p.nightly,
    (SELECT COUNT(*) FROM compat a JOIN compat b
       ON b.artifact = a.artifact AND b.nightly = NEW.nightly AND b.target = a.target AND b.source = 0 AND b.result IN (0, 1)
     WHERE a.nightly = p.nightly AND a.target = NEW.target AND a.source = 0 AND a.result IN (0, 1)),
    (SELECT COUNT(*) FROM compat a JOIN compat b
       ON b.artifact = a.artifact AND b.nightly = NEW.nightly AND b.target = a.target AND b.source = 0 AND b.result IN (0, 1)
     WHERE a.nightly = p.nightly AND a.target = NEW.target AND a.source = 0 AND a.result IN (0, 1) AND a.result <> b.result)
  FROM (
    SELECT (SELECT x.nightly FROM (SELECT nightly, MIN(published_at) AS t FROM toolchains GROUP BY nightly) x
      WHERE (x.nightly >> 28) < (NEW.nightly >> 28)
        OR ((x.nightly >> 28) = (NEW.nightly >> 28) AND x.t < (SELECT MIN(published_at) FROM toolchains WHERE nightly = NEW.nightly))
        OR ((x.nightly >> 28) = (NEW.nightly >> 28) AND x.t = (SELECT MIN(published_at) FROM toolchains WHERE nightly = NEW.nightly)
            AND x.nightly < NEW.nightly)
      ORDER BY (x.nightly >> 28) DESC, x.t DESC, x.nightly DESC LIMIT 1) AS nightly
    WHERE EXISTS (SELECT 1 FROM toolchains WHERE nightly = NEW.nightly)) p
  WHERE p.nightly IS NOT NULL AND EXISTS (SELECT 1 FROM sweeps s WHERE s.nightly = p.nightly AND s.target = NEW.target)
  ON CONFLICT (nightly, target) DO UPDATE SET
    previous = excluded.previous, compared = excluded.compared, changed = excluded.changed;
  INSERT INTO transitions (nightly, target, previous, compared, changed)
  SELECT q.nightly, NEW.target, NEW.nightly,
    (SELECT COUNT(*) FROM compat a JOIN compat b
       ON b.artifact = a.artifact AND b.nightly = q.nightly AND b.target = a.target AND b.source = 0 AND b.result IN (0, 1)
     WHERE a.nightly = NEW.nightly AND a.target = NEW.target AND a.source = 0 AND a.result IN (0, 1)),
    (SELECT COUNT(*) FROM compat a JOIN compat b
       ON b.artifact = a.artifact AND b.nightly = q.nightly AND b.target = a.target AND b.source = 0 AND b.result IN (0, 1)
     WHERE a.nightly = NEW.nightly AND a.target = NEW.target AND a.source = 0 AND a.result IN (0, 1) AND a.result <> b.result)
  FROM (
    SELECT (SELECT x.nightly FROM (SELECT nightly, MIN(published_at) AS t FROM toolchains GROUP BY nightly) x
      WHERE (x.nightly >> 28) > (NEW.nightly >> 28)
        OR ((x.nightly >> 28) = (NEW.nightly >> 28) AND x.t > (SELECT MIN(published_at) FROM toolchains WHERE nightly = NEW.nightly))
        OR ((x.nightly >> 28) = (NEW.nightly >> 28) AND x.t = (SELECT MIN(published_at) FROM toolchains WHERE nightly = NEW.nightly)
            AND x.nightly > NEW.nightly)
      ORDER BY (x.nightly >> 28), x.t, x.nightly LIMIT 1) AS nightly
    WHERE EXISTS (SELECT 1 FROM toolchains WHERE nightly = NEW.nightly)) q
  WHERE q.nightly IS NOT NULL AND EXISTS (SELECT 1 FROM sweeps s WHERE s.nightly = q.nightly AND s.target = NEW.target)
  ON CONFLICT (nightly, target) DO UPDATE SET
    previous = excluded.previous, compared = excluded.compared, changed = excluded.changed;
END;

-- R-CT13, R-RE12, R-RE13 row 3: a hint counts once. A row that ON CONFLICT DO NOTHING skips fires no AFTER trigger.
-- first_time is set once (Q82). last_time is the largest time. The day is NEW.time / 86400000. The limit is 200000.
CREATE TRIGGER contributions_count AFTER INSERT ON contributions
BEGIN
  INSERT INTO compat_hints (artifact, nightly, target, talon_version, pass_count, fail_count, crash_count, first_time, last_time)
  VALUES (NEW.artifact, NEW.nightly, NEW.target, NEW.talon_version,
    NEW.result = 0, NEW.result = 1, NEW.result = 3, NEW.time, NEW.time)
  ON CONFLICT (artifact, nightly, target, talon_version) DO UPDATE SET
    pass_count = pass_count + excluded.pass_count, fail_count = fail_count + excluded.fail_count,
    crash_count = crash_count + excluded.crash_count, last_time = MAX(last_time, excluded.last_time);
  INSERT INTO hint_days (day, counted) VALUES (NEW.time / 86400000, 1)
  ON CONFLICT (day) DO UPDATE SET counted = counted + 1;
  SELECT RAISE(ABORT, 'hint-quota') WHERE (SELECT counted FROM hint_days WHERE day = NEW.time / 86400000) > 200000;
END;
