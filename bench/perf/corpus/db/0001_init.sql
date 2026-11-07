-- Registry schema, P2 (slice 102). Registry 5, 5.1, R-RE1 to R-RE26, R-IK1 to R-IK8.
-- One statement for each semicolon. No PRAGMA, no BEGIN: D1 and node:sqlite take the same file.
-- Tables only. The triggers are in slice 103. There is no foreign key, no default value and no view.
-- Every table is STRICT (R-IK8). A time is an INTEGER, in ms since 1970 UTC (R-RE26).
-- A 64-bit id is an INTEGER column. The Worker binds it as text and reads it with CAST(id AS TEXT) (R-IK2).

-- R-IK3: one row for each name that a row refers to. kind: 1 blob, 2 and 3 text (R-IK2). The id is a function of (kind, value).
CREATE TABLE names (
  id INTEGER PRIMARY KEY,
  kind INTEGER NOT NULL CHECK (kind IN (1, 2, 3)),
  value ANY NOT NULL,
  UNIQUE (kind, value),
  CHECK (typeof(value) = CASE kind WHEN 1 THEN 'blob' ELSE 'text' END)
) STRICT;

-- R-IK7, R-RE21: a code for each Roc target. A new target takes the next code.
CREATE TABLE targets (
  target INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE
) STRICT;

-- R-RE1: one row for each artifact. kind: app 0, package 1, platform 2 (R-IK7, R-AP49).
CREATE TABLE artifacts (
  artifact INTEGER PRIMARY KEY,
  kind INTEGER NOT NULL CHECK (kind IN (0, 1, 2)),
  exposes TEXT NOT NULL,
  platform INTEGER,
  roc_pin TEXT,
  size INTEGER NOT NULL
) STRICT;

-- R-RE2, R-IK5, R-IK6: the label is (form, version, version_text), the key is log_index.
-- version is the semver key XOR 2^63 as a signed integer. version_text is empty when the key is exact.
-- yanked is 0 or 1. withdrawn is the wire value of R-AP49, or NULL (R-PU17).
CREATE TABLE releases (
  log_index INTEGER PRIMARY KEY,
  form INTEGER NOT NULL,
  version INTEGER NOT NULL,
  version_text TEXT NOT NULL,
  artifact INTEGER NOT NULL,
  repo INTEGER,
  url TEXT NOT NULL,
  tag TEXT,
  roc_version TEXT,
  published_at INTEGER NOT NULL,
  yanked INTEGER NOT NULL,
  withdrawn TEXT CHECK (withdrawn IN ('deleted', 'unpublished', 'prereleased', 'edited', 'asset-replaced', 'repo-missing')),
  withdrawn_at INTEGER,
  UNIQUE (form, version, version_text)
) STRICT;

CREATE INDEX releases_artifact ON releases (artifact, log_index);

-- R-RE3, R-IK7: source bot 0, author 1. result pass 0, fail 1, hang 2, crash 3.
CREATE TABLE compat (
  artifact INTEGER NOT NULL,
  nightly INTEGER NOT NULL,
  target INTEGER NOT NULL,
  source INTEGER NOT NULL CHECK (source IN (0, 1)),
  result INTEGER NOT NULL CHECK (result IN (0, 1, 2, 3)),
  error_digest TEXT,
  time INTEGER NOT NULL,
  log_index INTEGER,
  PRIMARY KEY (artifact, nightly, target, source)
) STRICT, WITHOUT ROWID;

CREATE INDEX compat_artifact_target ON compat (artifact, target, nightly);

CREATE INDEX compat_nightly ON compat (nightly, target, source, artifact);

-- R-RE4: target is the asset target of CLI 6.2 as text, for example linux_x86_64.
CREATE TABLE toolchains (
  nightly INTEGER NOT NULL,
  target TEXT NOT NULL,
  tag TEXT NOT NULL,
  asset_name TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  size INTEGER NOT NULL CHECK (size > 0),
  published_at INTEGER NOT NULL,
  log_index INTEGER NOT NULL,
  PRIMARY KEY (nightly, target)
) STRICT, WITHOUT ROWID;

-- R-SG1, R-SG2: the log. idx is max + 1, a used idx is an error (R-SG5).
CREATE TABLE log (
  idx INTEGER PRIMARY KEY,
  grp TEXT NOT NULL,
  version TEXT NOT NULL,
  hash TEXT NOT NULL,
  time INTEGER NOT NULL
) STRICT;

-- R-RE7
CREATE TABLE sweeps (
  nightly INTEGER NOT NULL,
  target INTEGER NOT NULL,
  upto_log_index INTEGER NOT NULL,
  time INTEGER NOT NULL,
  PRIMARY KEY (nightly, target)
) STRICT, WITHOUT ROWID;

-- R-RE23 (Design Q61): the transition of one nightly on one target.
CREATE TABLE transitions (
  nightly INTEGER NOT NULL,
  target INTEGER NOT NULL,
  previous INTEGER NOT NULL,
  compared INTEGER NOT NULL,
  changed INTEGER NOT NULL,
  PRIMARY KEY (nightly, target)
) STRICT, WITHOUT ROWID;

-- R-RE9: via oidc 0, webhook 1, poll 2, ingest 3. It keeps its rowid (the claims are a large field, R-IK8).
CREATE TABLE provenance (
  release INTEGER NOT NULL,
  via INTEGER NOT NULL CHECK (via IN (0, 1, 2, 3)),
  claims TEXT,
  time INTEGER NOT NULL,
  PRIMARY KEY (release, via)
) STRICT;

-- R-RE11: state active 0, missing 1, moved 2.
CREATE TABLE repos (
  repo INTEGER PRIMARY KEY,
  repository_id INTEGER NOT NULL,
  repository_owner_id INTEGER NOT NULL,
  state INTEGER NOT NULL CHECK (state IN (0, 1, 2)),
  successor INTEGER,
  state_at INTEGER NOT NULL,
  time INTEGER NOT NULL
) STRICT;

-- R-RE15: action bind 0, transfer 1, rename 2, recreate 3, missing 4, found 5, successor-set 6,
-- successor-removed 7, offer 8, operator 9.
CREATE TABLE repo_events (
  repo INTEGER NOT NULL,
  seq INTEGER NOT NULL,
  action INTEGER NOT NULL CHECK (action IN (0, 1, 2, 3, 4, 5, 6, 7, 8, 9)),
  repository_id_before INTEGER,
  repository_id_after INTEGER,
  owner_id_before INTEGER,
  owner_id_after INTEGER,
  successor INTEGER,
  claims TEXT,
  time INTEGER NOT NULL,
  PRIMARY KEY (repo, seq)
) STRICT;

-- R-RE14: the state of the reconcile. repo_etag: the ETag of GET /repositories/{id}, only for a public read of the name of the row (Design Q371, slice 119c).
CREATE TABLE repo_checks (
  repo INTEGER PRIMARY KEY,
  etag TEXT,
  checked_at INTEGER,
  next_check_at INTEGER NOT NULL,
  fail_count INTEGER NOT NULL,
  app_installed INTEGER NOT NULL,
  repo_etag TEXT
) STRICT;

-- R-RE12: user hints, summed for each (artifact, nightly, target, talon_version).
CREATE TABLE compat_hints (
  artifact INTEGER NOT NULL,
  nightly INTEGER NOT NULL,
  target INTEGER NOT NULL,
  talon_version INTEGER NOT NULL,
  pass_count INTEGER NOT NULL,
  fail_count INTEGER NOT NULL,
  crash_count INTEGER NOT NULL,
  first_time INTEGER NOT NULL,
  last_time INTEGER NOT NULL,
  PRIMARY KEY (artifact, nightly, target, talon_version)
) STRICT, WITHOUT ROWID;

-- R-RE16, R-CT2: a hang is not a hint, so result is pass 0, fail 1 or crash 3.
CREATE TABLE contributions (
  contributor INTEGER NOT NULL,
  artifact INTEGER NOT NULL,
  nightly INTEGER NOT NULL,
  target INTEGER NOT NULL,
  result INTEGER NOT NULL CHECK (result IN (0, 1, 3)),
  talon_version INTEGER NOT NULL,
  time INTEGER NOT NULL,
  PRIMARY KEY (contributor, artifact, nightly, target)
) STRICT, WITHOUT ROWID;

CREATE INDEX contributions_pair ON contributions (artifact, nightly, target, time);

CREATE INDEX contributions_nightly ON contributions (nightly);

-- R-RE17, R-CT3: a GitHub account has an id above 0. A machine has an id below 0 (an HMAC with the top bit set).
CREATE TABLE contributors (
  contributor INTEGER PRIMARY KEY CHECK (contributor > 0),
  login TEXT NOT NULL,
  tokens_after INTEGER NOT NULL,
  first_time INTEGER NOT NULL,
  last_time INTEGER NOT NULL
) STRICT;

-- R-RE18: a machine that logged in, and its account.
CREATE TABLE links (
  machine INTEGER PRIMARY KEY CHECK (machine < 0),
  contributor INTEGER NOT NULL,
  time INTEGER NOT NULL
) STRICT;

-- R-RE19: the dependencies of an artifact. form, version and version_text are NULL when the URL has no version.
-- R-AP81: platform is 1 for the platform entry of a package or platform header (Design Q251), else 0.
CREATE TABLE deps (
  artifact INTEGER NOT NULL,
  alias TEXT NOT NULL,
  dep INTEGER NOT NULL,
  form INTEGER,
  version INTEGER,
  version_text TEXT,
  url TEXT NOT NULL,
  platform INTEGER NOT NULL DEFAULT 0 CHECK (platform IN (0, 1)),
  PRIMARY KEY (artifact, alias)
) STRICT, WITHOUT ROWID;

-- R-RE20: the targets of a platform artifact.
CREATE TABLE artifact_targets (
  artifact INTEGER NOT NULL,
  target INTEGER NOT NULL,
  PRIMARY KEY (artifact, target)
) STRICT, WITHOUT ROWID;

-- R-RE24, R-RE25: the counter of the daily limit, and the totals of the trimmed hints.
CREATE TABLE hint_days (
  day INTEGER PRIMARY KEY,
  counted INTEGER NOT NULL
) STRICT;

CREATE TABLE contributor_totals (
  contributor INTEGER PRIMARY KEY,
  counted INTEGER NOT NULL,
  first INTEGER NOT NULL,
  agreed INTEGER NOT NULL,
  disagreed INTEGER NOT NULL,
  unconfirmed INTEGER NOT NULL,
  first_time INTEGER NOT NULL,
  last_time INTEGER NOT NULL
) STRICT;

-- R-IK7: code 0 is any, codes 1 to 35 are the RocTarget values in the order of the rule.
INSERT INTO targets (target, name) VALUES
  (0, 'any'),
  (1, 'x64mac'),
  (2, 'x64win'),
  (3, 'x64mingw'),
  (4, 'x64freebsd'),
  (5, 'x64openbsd'),
  (6, 'x64netbsd'),
  (7, 'x64musl'),
  (8, 'x64glibc'),
  (9, 'x64linux'),
  (10, 'x64elf'),
  (11, 'x64v1mac'),
  (12, 'x64v1win'),
  (13, 'x64v1mingw'),
  (14, 'x64v1freebsd'),
  (15, 'x64v1openbsd'),
  (16, 'x64v1netbsd'),
  (17, 'x64v1musl'),
  (18, 'x64v1glibc'),
  (19, 'x64v1linux'),
  (20, 'x64v1elf'),
  (21, 'arm64mac'),
  (22, 'arm64win'),
  (23, 'arm64mingw'),
  (24, 'arm64linux'),
  (25, 'arm64musl'),
  (26, 'arm64glibc'),
  (27, 'arm64v1win'),
  (28, 'arm64v1mingw'),
  (29, 'arm64v1linux'),
  (30, 'arm64v1musl'),
  (31, 'arm64v1glibc'),
  (32, 'arm32linux'),
  (33, 'arm32musl'),
  (34, 'wasm32'),
  (35, 'wasm32v1');
