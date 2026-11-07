## The handlers of the read routes (Registry 4: R-AP1, R-AP2, R-AP13, R-AP14; slice 106). The decisions are in `lib/Reads.roc` (pure, W0).
## This module only orders the effects. The tests are W2: `worker/tests/cases/reads/`. Each handler gives `Err(Refuse(problem))` for the answers
## that are problems (400, 404): `main.roc` turns it into the problem answer. `Err(Fault(text))` is a fault of the Worker: 500 `internal` (R-AP48).
## The flow of every read route (slice file section 3.3):
## 1. The route checks that do not need D1 come first and make no D1 call (R-AP48 row 6): the query (`Reads.parse_query`), the hash (`Reads.artifact_id`).
## 2. The cache key is `req.url()`. `Reads.bypass_cache` of the headers `cache-control` and `pragma`: false means `Cache.default.get!(key)` first.
##    A hit is the answer, with no D1 call. (A hit and a miss both go to step 5.)
## 3. A miss, or a bypass: `D1.with_session!(Reads.session_of(req.header("talon-bookmark")))`, then one call on the session (a statement, or one `batch!`), R-AP41.
## 4. The rows become the body with the builders of `Reads`. The answer is 200, `content-type: application/json`, `cache-control: Reads.cache_control`,
##    `etag: Reads.etag_of(body bytes)`. It goes into the Cache API (a bypass too). A 404 problem is not put in the Cache API (R-AP43).
## 5. `If-None-Match` against the `etag` of the answer: `Reads.etag_matches`. A match is 304 with no body and with the headers `etag` and `cache-control`.
import pf.Request
import pf.Response
import pf.D1
import pf.Sql
import pf.Cache
import pf.Time
import records.Release
import lib.Problem
import lib.Reads
import lib.Version

ReadRoutes :: [].{

	## The error of a read handler.
	Error : [Refuse(Problem), Fault(Str)]

	## `GET /v1/packages/{owner}/{repo}/releases` (R-AP1). The repo id is `Reads.repo_id(owner, repo)`. No row with this `releases.repo`: 404 `Reads.no_repo_releases`.
	repo_releases! : Request, Str, Str => Try(Response, ReadRoutes.Error)
	repo_releases! = |req, owner, repo| {
		page = "WITH page AS (SELECT * FROM releases WHERE repo = ?1 ORDER BY log_index)"
		id = Reads.repo_id(owner, repo)
		stmts = [Sql.stmt(releases_sql(page), [id]), Sql.stmt(repos_sql(page), [id])]
		serve!(req, Reads.cache_control, stmts, |results, now| repo_answer(results, now, owner, repo))
	}

	## `GET /v1/artifacts/{hash}` (R-AP2). `Reads.artifact_id`; no `artifacts` row: 404 `Reads.no_artifact`.
	artifact! : Request, Str => Try(Response, ReadRoutes.Error)
	artifact! = |req, hash| match Reads.artifact_id(hash) {
		Err(BadHash) => Err(Refuse(Reads.no_artifact(hash)))
		Ok(id) => {
			page = "WITH page AS (SELECT * FROM releases WHERE artifact = ?1 ORDER BY log_index)"
			stmts = [
				Sql.stmt(artifact_sql, [id]),
				Sql.stmt(deps_sql, [id]),
				Sql.stmt(targets_sql, [id]),
				Sql.stmt(releases_sql(page), [id]),
				Sql.stmt(repos_sql(page), [id]),
			]
			serve!(req, Reads.cache_control, stmts, |results, now| artifact_answer(results, now, hash))
		}
	}

	## `GET /v1/releases` (R-AP13, R-AP14): `Reads.parse_query` of the query parameters `group`, `series`, `after`. `ByGroup` gives `Reads.releases_body`
	## (also with `after`: the releases of the group with a larger `log_index`, at most `Reads.page_limit`). `ByAfter` gives `Reads.page_body`.
	## All lists are in `log_index` order. A group with no release is 200 with `"releases":[]` (R-AP13 has no 404).
	releases! : Request => Try(Response, ReadRoutes.Error)
	releases! = |req| match Reads.parse_query({ group: req.query("group"), series: req.query("series"), after: req.query("after") }) {
		Err(problem) => Err(Refuse(problem))
		Ok(ByAfter(after)) => {
			page = "WITH page AS (SELECT * FROM releases WHERE log_index > ?1 ORDER BY log_index LIMIT ${U64.to_str(Reads.page_limit)})"
			id = after.to_i64_wrap()
			stmts = [Sql.stmt(releases_sql(page), [id]), Sql.stmt(repos_sql(page), [id])]
			serve!(req, Reads.cache_control, stmts, |results, now| after_answer(results, now))
		}
		Ok(ByGroup(query)) => {
			page = "WITH page AS (SELECT * FROM releases WHERE form = ?1 AND version BETWEEN CAST(?2 AS INTEGER) AND CAST(?3 AS INTEGER) AND log_index > ?4 ORDER BY log_index LIMIT CAST(?5 AS INTEGER))"
			bounds = series_bounds(query.series)
			after = match query.after {
				Ok(n) => n.to_i64_wrap()
				Err(None) => -1
			}
			limit = match query.after {
				Ok(_) => Reads.page_limit.to_i64_wrap()
				Err(None) => -1
			}
			params = (Reads.form_id(query.group), bounds.lo, bounds.hi, after, limit)
			stmts = [Sql.stmt(releases_sql(page), params), Sql.stmt(repos_sql(page), params)]
			serve!(req, Reads.cache_control, stmts, |results, now| group_answer(results, now, query.series))
		}
	}

	## The row of `repos` joined with `repo_checks` and the names (one statement for `checked` and `repos`).
	RepoCheckRow : { name : Str, state : I64, successor : Try(Str, [Missing]), state_at : U64, checked_at : Try(U64, [Missing]), app_installed : Bool }

	Tail : { checked : Try(Reads.CheckedItem, [None]), repos : List(Reads.RepoItem) }

	## The flow of every read route (the header of this file, steps 2 to 5). `stmts` is the one batch of step 3, `build` makes the body text of step 4 from its results
	## and the time. A problem (404) comes out of `build` as `Err(Refuse(..))` and is not put in the Cache API.
	## `cache_control` is the `Cache-Control` of the 200 and of the 304 answer (`Reads.cache_control` for the routes of slice 106, other values for slice 107).
	serve! : Request, Str, List(Sql.Stmt), (List(D1.Result), U64 -> Try(Str, ReadRoutes.Error)) => Try(Response, ReadRoutes.Error)
	serve! = |req, cache_control, stmts, build| {
		key = req.url()
		bypass = Reads.bypass_cache({ cache_control: req.header("cache-control"), pragma: req.header("pragma") })
		if_none_match = req.header("if-none-match")
		match (if (bypass) Err(Miss) else Cache.default.get!(key).map_err(|_| Miss)) {
			Ok(hit) => Ok(answer_hit(hit, if_none_match, cache_control))
			Err(_) => {
				body = read!(req, stmts, build)?
				bytes = body.to_utf8()
				etag = Reads.etag_of(bytes)
				res = Response.from_bytes(200, "application/json", bytes).with_header("cache-control", cache_control).with_header("etag", etag)
				sent = Cache.default.put!(key, res) ?? res
				Ok(if (matches(if_none_match, etag)) not_modified(etag, cache_control) else sent)
			}
		}
	}

	## Step 3: one session, one batch.
	read! : Request, List(Sql.Stmt), (List(D1.Result), U64 -> Try(Str, ReadRoutes.Error)) => Try(Str, ReadRoutes.Error)
	read! = |req, stmts, build| {
		session = db.with_session!(Reads.session_of(req.header("talon-bookmark"))).map_err(|e| Fault(Str.inspect(e)))?
		results = session.batch!(stmts).map_err(|e| Fault(Str.inspect(e)))?
		build(results, Time.now_ms!())
	}

	## Step 5 for an answer of the Cache API.
	answer_hit : Response, Try(Str, [NotFound]), Str -> Response
	answer_hit = |hit, if_none_match, cache_control| match hit.header("etag") {
		Ok(etag) => if (matches(if_none_match, etag)) not_modified(etag, cache_control) else hit
		Err(NotFound) => hit
	}

	matches : Try(Str, [NotFound]), Str -> Bool
	matches = |if_none_match, etag| match if_none_match {
		Ok(text) => Reads.etag_matches(text, etag)
		Err(NotFound) => Bool.False
	}

	not_modified : Str, Str -> Response
	not_modified = |etag, cache_control| Response.from_status(304).with_header("etag", etag).with_header("cache-control", cache_control)

	# ---- the bodies: rows to text (pure) ----

	repo_answer : List(D1.Result), U64, Str, Str -> Try(Str, ReadRoutes.Error)
	repo_answer = |results, now, owner, repo| match results {
		[rel, rep] => {
			releases = releases_of(rel)?
			if releases.is_empty() {
				Err(Refuse(Reads.no_repo_releases(owner, repo)))
			} else {
				tail = tail_of(rep, now)?
				Ok(Reads.releases_body({ releases, checked: tail.checked, repos: tail.repos }))
			}
		}
		_ => Err(Fault("repo releases: the batch gave ${U64.to_str(results.len())} results, not 2"))
	}

	group_answer : List(D1.Result), U64, Try(Str, [None]) -> Try(Str, ReadRoutes.Error)
	group_answer = |results, now, series| match results {
		[rel, rep] => {
			all = releases_of(rel)?
			releases = match series {
				Ok(text) => all.keep_if(|r| r.series == text)
				Err(None) => all
			}
			tail = tail_of(rep, now)?
			Ok(Reads.releases_body({ releases, checked: tail.checked, repos: tail.repos }))
		}
		_ => Err(Fault("releases: the batch gave ${U64.to_str(results.len())} results, not 2"))
	}

	after_answer : List(D1.Result), U64 -> Try(Str, ReadRoutes.Error)
	after_answer = |results, now| match results {
		[rel, rep] => {
			releases = releases_of(rel)?
			tail = tail_of(rep, now)?
			Ok(Reads.page_body({ releases, repos: tail.repos }))
		}
		_ => Err(Fault("releases: the batch gave ${U64.to_str(results.len())} results, not 2"))
	}

	artifact_answer : List(D1.Result), U64, Str -> Try(Str, ReadRoutes.Error)
	artifact_answer = |results, now, hash| match results {
		[art, dep, tgt, rel, rep] => {
			artifacts : List(Reads.ArtifactRow)
			artifacts = art.all().map_err(|e| Fault(Str.inspect(e)))?
			match artifacts {
				[] => Err(Refuse(Reads.no_artifact(hash)))
				[row, ..] => {
					deps : List(Reads.DepRow)
					deps = dep.all().map_err(|e| Fault(Str.inspect(e)))?
					names : List({ name : Str })
					names = tgt.all().map_err(|e| Fault(Str.inspect(e)))?
					artifact = Reads.artifact_of_rows({ artifact: row, deps, target_names: names.map(|t| t.name) }).map_err(bad_row)?
					releases = releases_of(rel)?
					tail = tail_of(rep, now)?
					Ok(Reads.artifact_body({ artifact, releases, repos: tail.repos }))
				}
			}
		}
		_ => Err(Fault("artifact: the batch gave ${U64.to_str(results.len())} results, not 5"))
	}

	releases_of : D1.Result -> Try(List(Release.Row), ReadRoutes.Error)
	releases_of = |result| {
		rows : List(Reads.ReleaseRow)
		rows = result.all().map_err(|e| Fault(Str.inspect(e)))?
		rows.map_try(Reads.release_of_row).map_err(bad_row)
	}

	## `repos` from the rows. `checked` is the item of the first repo (R-AP53: one item, or none).
	tail_of : D1.Result, U64 -> Try(ReadRoutes.Tail, ReadRoutes.Error)
	tail_of = |result, now| {
		rows : List(ReadRoutes.RepoCheckRow)
		rows = result.all().map_err(|e| Fault(Str.inspect(e)))?
		repos = rows.map_try(|r| Reads.repo_item_of_row({ name: r.name, state: r.state, successor: r.successor, state_at: r.state_at })).map_err(bad_row)?
		checked = match rows {
			[first, ..] => Ok(Reads.checked_of_row({ name: first.name, checked_at: first.checked_at, app_installed: first.app_installed }, now))
			[] => Err(None)
		}
		Ok({ checked, repos })
	}

	bad_row : [BadRow(Str)] -> ReadRoutes.Error
	bad_row = |e| match e {
		BadRow(text) => Fault(text)
	}

	## The lower and upper end of `?series=` as column values (R-IK5). `parse_query` has checked the text, so the fallback is the whole range:
	## the filter on the `series` of each row is then the only filter.
	series_bounds : Try(Str, [None]) -> Version.Bounds
	series_bounds = |series| {
		all = { lo: "-9223372036854775808", hi: "9223372036854775807" }
		match series {
			Ok(text) => Version.series_bounds(text) ?? all
			Err(None) => all
		}
	}

	# ---- the SQL (slice file section 3.4): every hash is the BLOB `names.value`, every version is `CAST(version AS TEXT)` ----

	db = D1.binding("DB")

	## The rows of the releases of a CTE `page`, in `log_index` order.
	releases_sql : Str -> Str
	releases_sql = |page| "${page} SELECT r.log_index AS log_index, an.value AS hash, fn.value AS form, CAST(r.version AS TEXT) AS version, r.version_text AS version_text, r.url AS url, r.tag AS tag, r.roc_version AS roc_version, rn.value AS repo, r.published_at AS published_at, r.yanked AS yanked, r.withdrawn AS withdrawn, (SELECT group_concat(via) FROM (SELECT via FROM provenance WHERE release = r.log_index ORDER BY via)) AS vias FROM page r JOIN names an ON an.id = r.artifact JOIN names fn ON fn.id = r.form LEFT JOIN names rn ON rn.id = r.repo ORDER BY r.log_index"

	## The repos of the releases of a CTE `page`, with their check, sorted by name (bytes).
	repos_sql : Str -> Str
	repos_sql = |page| "${page} SELECT rn.value AS name, p.state AS state, sn.value AS successor, p.state_at AS state_at, c.checked_at AS checked_at, COALESCE(c.app_installed, 0) AS app_installed FROM repos p JOIN names rn ON rn.id = p.repo LEFT JOIN names sn ON sn.id = p.successor LEFT JOIN repo_checks c ON c.repo = p.repo WHERE p.repo IN (SELECT repo FROM page) ORDER BY rn.value"

	artifact_sql : Str
	artifact_sql = "SELECT an.value AS hash, a.kind AS kind, a.exposes AS exposed_json, pl.value AS platform_hash, a.roc_pin AS roc_pin, a.size AS size FROM artifacts a JOIN names an ON an.id = a.artifact LEFT JOIN names pl ON pl.id = a.platform WHERE a.artifact = ?1"

	deps_sql : Str
	deps_sql = "SELECT d.alias AS alias, dn.value AS hash, fn.value AS form, CAST(d.version AS TEXT) AS version, d.version_text AS version_text, d.url AS url, d.platform AS is_platform FROM deps d JOIN names dn ON dn.id = d.dep LEFT JOIN names fn ON fn.id = d.form WHERE d.artifact = ?1 ORDER BY d.alias"

	targets_sql : Str
	targets_sql = "SELECT t.name AS name FROM artifact_targets x JOIN targets t ON t.target = x.target WHERE x.artifact = ?1 ORDER BY t.name"
}
