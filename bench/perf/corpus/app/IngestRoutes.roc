## The handler of the ingest `POST /v1/releases` with no `Authorization` (Registry 4: R-AP9, R-AP26, R-AP41; 7: R-PU4, R-PU6, R-PU14, R-PU15, R-PU19, R-PU26,
## R-PU31, R-PU32; 5.1: R-IK3; 7.1: R-TP5; slice 112). The decisions are in `lib/Ingest.roc` (pure, W0). This module only orders the effects.
## The tests are W2: `worker/tests/cases/ingest/`. `Err(Refuse(problem))` is a problem answer, `Err(Fault(text))` is 500 `internal` (R-AP48, never a `crash`).
## `main.roc` calls `post!` only for a request with no `Authorization` header (R-AP26: a token is a publish, slice 114).
##
## Flow (Registry R-AP68 rows 1, 2, 4, 6 to 11; Design Q155 to Q165; rows 3, 5 and 12 are slice 112b):
## 1. `req.bytes_with!({ max_bytes: 262144 })` (R-AP46). `Err(TooLarge)`: 413 `too-large` with `field` `body` and `limit` 262144 (as `ClosureRoute`). Another `Err`: the bytes `[]`.
##    `Ingest.parse_body`, then `Ingest.parse_url`. A refusal makes no D1 call and no GitHub call.
## 2. One session `db.with_session!(Primary)` for all the D1 calls of the request (a write reads the newest state, R-AP41 row 5).
##    D1 call 1, the pre-read: the `Ingest.LabelRow` of the label (`releases.form` = the form id, `version`, `version_text` of `target.column`; the columns of
##    `Reads.ReleaseRow` as `ReadRoutes` reads them, and `EXISTS (SELECT 1 FROM provenance WHERE release = log_index AND via = 3)` as `has_ingest`).
##    `Ingest.after_read`: `Conflict` is `Refuse`. `Answer(release)` is the answer 200 (step 7). `AddProvenance` and `Index` go on.
## 3. GitHub `GET Ingest.repo_url(target)` (headers `user-agent: talon-registry`, `accept: application/vnd.github+json`). 404: `Ingest.not_public`.
##    Another status than 200: `Ingest.github_status("repository", s)`. No answer: `github_no_answer("repository")`. `Ingest.parse_repo` refuses: `github_bad("repository")`.
##    `public` is false: `Ingest.not_public` (R-PU32: nothing is written, and the log line has the problem type only).
## 4. `AddProvenance(log_index)`: D1 call 2, one batch: the provenance statement of section 3.2 row 8 and the read of step 2. Status 200 (step 7).
## 5. `Index`: GitHub `GET Ingest.release_url(target)` (the same headers). 404: `Ingest.no_release(tag)`. Another status: `github_status("release", s)`. No answer, or
##    `Ingest.parse_release` refuses: `github_no_answer("release")`, `github_bad("release")`. Then `Ingest.candidate`.
##    `Archive.read!(target.url, target.hash)`: `Refused(r)` is `ArchiveRead.problem(r)`, `Upstream(u)` is `ArchiveRead.upstream_problem(u)` (502), `Fault` is `Fault`.
##    GitHub `GET Ingest.roc_version_url(target)` with the header `user-agent: talon-registry`: 200 is `Ok(Ingest.roc_version_of(text))`, 404 is `Err(None)`,
##    another status `github_status(".roc-version", s)`, no answer `github_no_answer(".roc-version")`.
## 6. `Ingest.plan` with `Time.now_ms!()` (once for the request). D1 call 2: one batch with the statements of the slice file section 3.2, in that order, and last the read of step 2.
##    `Err(Constraint(c))`: `Ingest.batch_failure(c)`. `LabelConflict`: `Refuse(Ingest.label_conflict(target, Err(None)))`. `IdCollision`: D1 call 3, the read of
##    `Ingest.NameRow` for the ids of `plan.names`, then `Refuse(Ingest.collision(plan.names, rows))`. `Fault`: `Fault`.
## 7. The answer: the status `Ingest.status_of(<changes of the releases statement>)` (200 for steps 2 and 4), `content-type: application/json`,
##    `cache-control: Ingest.cache_control`, the body `Ingest.answer_body(release)` (`Reads.release_of_row` of the row of the last statement),
##    `talon-bookmark: <session.bookmark!()>` after the last D1 call (R-AP41 row 5), and for a 201 `location: Ingest.location(hash)`. A problem answer has no `talon-bookmark` (Q165).
import pf.Request
import pf.Response
import pf.D1
import pf.Sql
import pf.Time
import pf.Cache
import pf.Env
import pf.Log
import pf.RateLimit
import records.Release
import lib.ArchiveRead
import lib.Client
import lib.Ingest
import lib.Identity
import lib.IngestLimits
import lib.Problem
import lib.Reads
import lib.Version
import Archive
import GithubRead
import lib.GithubApp

IngestRoutes :: [].{

	## The error of the handler: the same form as `ReadRoutes.Error`.
	Error : [Refuse(Problem), Fault(Str)]

	post! : Request => Try(Response, IngestRoutes.Error)
	post! = |req| {
		bytes = match req.bytes_with!({ max_bytes: body_limit }) {
			Ok(b) => b
			Err(TooLarge) => return Ok(too_large)
			Err(BodyErr(_)) => []
		}
		url = Ingest.parse_body(bytes).map_err(|p| Refuse(p))?
		target = Ingest.parse_url(url).map_err(|p| Refuse(p))?
		match limiter.limit!(Client.rate_key(req.header("cf-connecting-ip"))) {
			Ok({}) => {}
			Err(RateLimited) => return Ok(limited_response(IngestLimits.ip_limited, IngestLimits.ip_retry_after))
			Err(Infra(e)) => return Err(fault(e))
		}
		session = db.with_session!(Primary).map_err(fault)?
		now_ms = Time.now_ms!()
		repo_id = Reads.repo_id(target.owner, target.repo)
		first = session.batch!([Sql.stmt(label_sql, label_params(target)), owner_stmt(target, now_ms), Sql.stmt(repo_sql, [repo_id])]).map_err(fault)?
		rows = label_rows(first.first().map_err(|_| Fault("the pre-read gave no result"))?.all())?
		old = old_row(first, 2, repo_id)?
		match Ingest.after_read(target, rows).map_err(bad_row)? {
			Conflict(problem) => Err(Refuse(problem))
			Answer(release) => answer!(session, 200, release)
			AddProvenance(log_index) => {
				github_repo = read_repo!(target)?
				now = Time.now_ms!()
				identity = match identity!(target, repo_id, github_repo, old, now, Err(None))? {
					Stop(response) => return Ok(response)
					Go(done) => done.stmts
				}
				provenance = Sql.stmt("INSERT INTO provenance (release, via, claims, time) SELECT ?1, 3, NULL, ?2 WHERE NOT EXISTS (SELECT 1 FROM provenance WHERE release = ?1 AND via = 3)", (log_index, now))
				stmts = [provenance].concat(identity).append(Sql.stmt(label_sql, label_params(target)))
				results = session.batch!(stmts).map_err(fault)?
				dropping(answer!(session, 200, last_release(results)?), req, target, 200)
			}
			Index => {
				match IngestLimits.owner_check(owner_input(target, first, now_ms)?) {
					Err((problem, seconds)) => return Ok(limited_response(problem, seconds))
					Ok({}) => {}
				}
				github_repo = read_repo!(target)?
				now = Time.now_ms!()
				identity = match identity!(target, repo_id, github_repo, old, now, Err(None))? {
					Stop(response) => return Ok(response)
					Go(done) => done.stmts
				}
				flow = {
					repo: github_repo.repo,
					identity,
					now,
					via: 3,
					claims: Err(None),
					extra: [],
					candidate: Ingest.candidate,
					no_release: Ingest.no_release,
				}
				dropping(index!(session, target, flow), req, target, 201)
			}
		}
	}

	## R-AP68 row 3 (R-PU34 row 1): 60 ingests a minute for each rate key.
	limiter = RateLimit.binding(IngestLimits.ip_binding)

	## The answer 429 of a limit (R-AP25): `Retry-After` in seconds. No `talon-bookmark` (Q165).
	limited_response : Problem, U64 -> Response
	limited_response = |problem, seconds| Response.from_bytes(problem.http_status(), "application/problem+json", problem.to_json().to_utf8()).with_header("retry-after", seconds.to_str())

	## R-AP68 row 5: the second statement of D1 call 1. The count of the `repos` rows of the owner from 00:00 UTC (the `names` values of kind 3 in the byte range
	## `[<owner>/, <owner>0)`), and whether the name of the URL has a `repos` row.
	owner_stmt : Ingest.Target, U64 -> Sql.Stmt
	owner_stmt = |target, now_ms| {
		range = IngestLimits.owner_range(IngestLimits.owner_of(target.name))
		Sql.stmt(
			"SELECT (SELECT COUNT(*) FROM repos r JOIN names n ON n.id = r.repo WHERE n.kind = 3 AND n.value >= ?1 AND n.value < ?2 AND r.time >= ?3) AS count, EXISTS (SELECT 1 FROM repos r JOIN names n ON n.id = r.repo WHERE n.kind = 3 AND n.value = ?4) AS has_repo",
			(range.lo, range.hi, IngestLimits.day_start(now_ms), target.name),
		)
	}

	OwnerSqlRow : { count : U64, has_repo : Bool }

	owner_input : Ingest.Target, List(D1.Result), U64 -> Try({ owner : Str, has_repo : Bool, count : U64, now_ms : U64 }, IngestRoutes.Error)
	owner_input = |target, results, now_ms| {
		result = results.get(1).map_err(|_| Fault("the pre-read gave no owner result"))?
		rows : Try(List(IngestRoutes.OwnerSqlRow), _)
		rows = result.all()
		match rows.map_err(fault)? {
			[row, ..] => Ok({ owner: IngestLimits.owner_of(target.name), has_repo: row.has_repo, count: row.count, now_ms })
			[] => Err(Fault("the owner count gave no row"))
		}
	}

	## R-AP69, R-AP43: after a good answer that wrote (a 200 of the provenance row, a 201), `Response.after` drops the 4 cache keys of the release.
	## A failed drop is a log line. `Err` and an answer with another status than `status` pass unchanged (the 200 of an `Index` that wrote no release drops nothing).
	dropping : Try(Response, IngestRoutes.Error), Request, Ingest.Target, U16 -> Try(Response, IngestRoutes.Error)
	dropping = |result, req, target, status| result.map_ok(
		|res| if (res.status() != status) res else {
			keys = IngestLimits.drop_keys({ origin: origin_of(req.url()), group: target.form, series: Version.series_of(target.version), name: target.name, hash: target.hash })
			work! = || {
				for key in keys {
					match Cache.default.delete!(key) {
						Ok({}) | Err(NotFound) => {}
						Err(e) => Log.warn!("cache drop failed", { key, error: Str.inspect(e) })
					}
				}
				Ok({})
			}
			res.after(work!)
		},
	)

	## The scheme and host of a URL: `https://host`.
	origin_of : Str -> Str
	origin_of = |url| Str.join_with(url.split_on("/").take_first(3), "/")

	## R-AP46: the most bytes of the body.
	body_limit : U64
	body_limit = 262144

	too_large : Response
	too_large = {
		problem = Problem.new(TooLarge, "the body of the ingest request is larger than its limit of ${body_limit.to_str()}")
		Response.from_bytes(413, "application/problem+json", Problem.to_json_with(problem, { field: "body", limit: body_limit }).to_utf8())
	}

	## What `index!` needs from its caller (the ingest and the publish, slice 114). `repo` is what the GitHub read of the repository shows (the ingest) or what the claims show (the publish).
	## `identity` has the statements of the identity. `now` is the clock of the request. `via` and `claims` are the code and the claims of the provenance row of a new release.
	## `extra` has the statements after the identity (the author facts of a publish). `candidate` and `no_release` are the rules of the release read.
	Flow : {
		repo : Ingest.Repo,
		identity : List(Sql.Stmt),
		now : U64,
		via : U8,
		claims : Try(Str, [None]),
		extra : List(Sql.Stmt),
		candidate : Ingest.Target, Ingest.GithubRelease -> Try(U64, Problem),
		no_release : Str -> Problem,
	}

	## Steps 5, 6: the release read, the archive read, and the write batch. The caller has done the repository read and the identity.
	index! : D1.Session, Ingest.Target, IngestRoutes.Flow => Try(Response, IngestRoutes.Error)
	index! = |session, target, flow| {
		repo = flow.repo
		now = flow.now
		release_text = match github!(Ingest.release_url(target), "release")? {
			Found(text) => text
			Missing => return Err(Refuse((flow.no_release)(target.tag)))
		}
		release = Ingest.parse_release(release_text).map_err(|_| Refuse(Ingest.github_bad("release")))?
		published_at = (flow.candidate)(target, release).map_err(|p| Refuse(p))?
		artifact = Archive.read!(target.url, target.hash).map_err(
			|e| match e {
				Refused(r) => Refuse(ArchiveRead.problem(r))
				Upstream(u) => Refuse(ArchiveRead.upstream_problem(u))
				Fault(text) => Fault(text)
			},
		)?
		roc_version = match github!(Ingest.roc_version_url(target), ".roc-version")? {
			Found(text) => Ok(Ingest.roc_version_of(text))
			Missing => Err(None)
		}
		plan = Ingest.plan({ target, repo, artifact, published_at, roc_version, now_ms: now })
		writes = writes_of(plan, flow.via, flow.claims).concat(flow.identity).concat(flow.extra)
		release_at = plan.names.len() + plan.new_targets.len() + 1 + plan.deps.len() + plan.target_names.len() + 1
		match session.batch!(writes.append(Sql.stmt(label_sql, label_params(target)))) {
			Ok(results) => {
				changes = results.get(release_at).map_ok(|r| r.info().changes) ?? 0
				answer!(session, Ingest.status_of(changes), last_release(results)?)
			}
			Err(Constraint(c)) => match Ingest.batch_failure(c) {
				LabelConflict => Err(Refuse(Ingest.label_conflict(target, Err(None))))
				IdCollision => {
					ids = plan.names.map(|n| n.id)
					marks = Str.join_with(ids.map(|_| "?"), ", ")
					found : Try(List(Ingest.NameRow), _)
					found = session.all!("SELECT CAST(id AS TEXT) AS id, kind, CAST(value AS BLOB) AS value FROM names WHERE id IN (${marks})", ids)
					Err(Refuse(Ingest.collision(plan.names, found.map_err(fault)?)))
				}
				Fault => Err(Fault(c.message))
			}
			Err(e) => Err(fault(e))
		}
	}

	## Step 3: the visibility read (R-PU31, R-PU32).
	## `full_name` is `F` of R-TP18: the name of the answer, after the 301 of an old name.
	read_repo! : Ingest.Target => Try({ repo : Ingest.Repo, full_name : Str }, IngestRoutes.Error)
	read_repo! = |target| match github!(Ingest.repo_url(target), "repository")? {
		Missing => Err(Refuse(Ingest.not_public))
		Found(text) => match Ingest.parse_repo(text) {
			Ok(repo) if repo.public => match Identity.full_name_of(text) {
				Ok(full_name) => Ok({ repo, full_name })
				Err(BadRepo) => Err(Refuse(Ingest.github_bad(what_repo)))
			}
			Ok(_) => Err(Refuse(Ingest.not_public))
			Err(BadRepo) => Err(Refuse(Ingest.github_bad(what_repo)))
		}
	}

	what_repo : Str
	what_repo = "repository"

	## One GitHub `GET`: 200 is `Found(text)`, 404 is `Missing`, another status or no answer is 502 `upstream`.
	github! : Str, Str => Try([Found(Str), Missing], IngestRoutes.Error)
	github! = |url, what| {
		res = match GithubRead.send!(Request.get(url)) {
			Ok(found) => found
			Err(NoAnswer) => return Err(Refuse(Ingest.github_no_answer(what)))
			Err(Token(failure)) => return Err(token_error(failure))
		}
		status = res.status()
		if status == 404 {
			Ok(Missing)
		} else if status != 200 {
			Err(Refuse(Ingest.github_status(what, status)))
		} else {
			res.text!().map_ok(|text| Found(text)).map_err(|_| Refuse(Ingest.github_bad(what)))
		}
	}

	## R-PU25, Q4: a setting or sign fault is 500 `internal` (`Fault`), a failed token request is 502 `upstream`.
	token_error : GithubApp.Failure -> IngestRoutes.Error
	token_error = |failure| match GithubApp.failure_class(failure) {
		Upstream(detail) => Refuse(Problem.new(Upstream, detail))
		Fault(text) => Fault(text)
	}

	## The answer 200 or 201 (step 7), with the bookmark of the session after its last call (R-AP41 row 5).
	answer! : D1.Session, U16, Release.Row => Try(Response, IngestRoutes.Error)
	answer! = |session, status, release| {
		base = Response.from_bytes(status, "application/json", Ingest.answer_body(release).to_utf8()).with_header("cache-control", Ingest.cache_control)
		located = if (status == 201) base.with_header("location", Ingest.location(release.hash)) else base
		Ok(
			match session.bookmark!() {
				Ok(bookmark) => located.with_header("talon-bookmark", bookmark)
				Err(NotFound) => located
			},
		)
	}

	# ---- the label read (step 2, and the last statement of a batch) ----

	## The columns of `Reads.ReleaseRow` and `has_ingest`, in one flat row.
	LabelSqlRow : {
		log_index : U64,
		hash : List(U8),
		form : Str,
		version : Str,
		version_text : Str,
		url : Str,
		tag : Try(Str, [Missing]),
		roc_version : Try(Str, [Missing]),
		repo : Try(Str, [Missing]),
		published_at : U64,
		yanked : Bool,
		withdrawn : Try(Str, [Missing]),
		vias : Try(Str, [Missing]),
		has_ingest : Bool,
	}

	## `via` is the code of the provenance row that `has_ingest` asks for: 3 (`ingest`) for the ingest, 0 (`oidc`) for the publish.
	label_sql_of : U8 -> Str
	label_sql_of = |via| "SELECT r.log_index AS log_index, an.value AS hash, fn.value AS form, CAST(r.version AS TEXT) AS version, r.version_text AS version_text, r.url AS url, r.tag AS tag, r.roc_version AS roc_version, rn.value AS repo, r.published_at AS published_at, r.yanked AS yanked, r.withdrawn AS withdrawn, (SELECT group_concat(via) FROM (SELECT via FROM provenance WHERE release = r.log_index ORDER BY via)) AS vias, EXISTS (SELECT 1 FROM provenance p WHERE p.release = r.log_index AND p.via = ${via.to_str()}) AS has_ingest FROM releases r JOIN names an ON an.id = r.artifact JOIN names fn ON fn.id = r.form LEFT JOIN names rn ON rn.id = r.repo WHERE r.form = ?1 AND r.version = ?2 AND r.version_text = ?3"

	label_sql : Str
	label_sql = label_sql_of(3)

	label_params : Ingest.Target -> (I64, Str, Str)
	label_params = |t| (Reads.form_id(t.form), t.column.version, t.column.version_text)

	label_rows : Try(List(IngestRoutes.LabelSqlRow), _) -> Try(List(Ingest.LabelRow), IngestRoutes.Error)
	label_rows = |read| {
		rows = read.map_err(fault)?
		Ok(
			rows.map(
				|r| {
					release: {
						log_index: r.log_index,
						hash: r.hash,
						form: r.form,
						version: r.version,
						version_text: r.version_text,
						url: r.url,
						tag: r.tag,
						roc_version: r.roc_version,
						repo: r.repo,
						published_at: r.published_at,
						yanked: r.yanked,
						withdrawn: r.withdrawn,
						vias: r.vias,
					},
					has_ingest: r.has_ingest,
				},
			),
		)
	}

	## The release of the label read, the last statement of a batch.
	last_release : List(D1.Result) -> Try(Release.Row, IngestRoutes.Error)
	last_release = |results| {
		last = results.last().map_err(|_| Fault("the batch gave no result"))?
		rows = label_rows(last.all())?
		match rows {
			[row, ..] => Reads.release_of_row(row.release).map_err(bad_row)
			[] => Err(Fault("the label has no row after the write batch"))
		}
	}

	# ---- the identity of the repository (slice 113: R-TP9 to R-TP13, R-TP18, R-TP19) ----

	## The `repos` row of the name, the third statement of D1 call 1. The id of a successor is read as text (64 bits).
	repo_sql : Str
	repo_sql = "SELECT repository_id, repository_owner_id, state, CAST(successor AS TEXT) AS successor, state_at, time FROM repos WHERE repo = ?1"

	RepoSqlRow : { repository_id : U64, repository_owner_id : U64, state : U64, successor : Try(Str, [Missing]), state_at : U64, time : U64 }

	## `at` is the place of the `repos` result in the batch: 2 for the ingest (after the owner count), 1 for the publish.
	old_row : List(D1.Result), U64, I64 -> Try(Try(Identity.Row, [None]), IngestRoutes.Error)
	old_row = |results, at, repo| {
		result = results.get(at).map_err(|_| Fault("the pre-read gave no repos result"))?
		rows : Try(List(IngestRoutes.RepoSqlRow), _)
		rows = result.all()
		match rows.map_err(fault)? {
			[] => Ok(Err(None))
			[r, ..] => {
				state = match r.state {
					0 => Active
					1 => Missing
					2 => Moved
					_ => return Err(Fault("a repos row has a state that is not 0, 1 or 2"))
				}
				successor = match r.successor {
					Ok(text) => Ok(I64.from_str(text).map_err(|_| Fault("a repos row has a successor that is not a number"))?)
					Err(Missing) => Err(None)
				}
				Ok(Ok({ repo, repository_id: r.repository_id, owner_id: r.repository_owner_id, state, successor, state_at: r.state_at, time: r.time }))
			}
		}
	}

	## R-TP9 (C1), R-TP12: the ids of the GitHub answer against the row of D1 call 1. No D1 call. `Stop` is the answer 403 `repository-changed`
	## (no `talon-bookmark`, Q165). `Go` has the statements of the write batch, and `has_events`: true when the batch writes an event of the identity (R-TP13).
	## `claims` is the claims text of a publish (R-TP13), or `Err(None)` for an ingest: it is the column `repo_events.claims`.
	identity! : Ingest.Target, I64, { repo : Ingest.Repo, full_name : Str }, Try(Identity.Row, [None]), U64, Try(Str, [None]) => Try([Go({ stmts : List(Sql.Stmt), has_events : Bool }), Stop(Response)], IngestRoutes.Error)
	identity! = |target, repo_id, github_repo, old, now, claims| {
		seen = { repository_id: github_repo.repo.id, owner_id: github_repo.repo.owner_id }
		match Identity.decide({ repo: repo_id, row: old, seen, now }) {
			Ok(change) => {
				same = Identity.renamed(target.name, github_repo.full_name) == Err(Same)
				input = { u: repo_id, same, old, change, now, claims }
				Ok(Go({ stmts: identity_stmts(input), has_events: !change.events.is_empty() or rename_back_applies(input) }))
			}
			Err(Changed) => {
				bound = match old {
					Ok(row) => row.repository_id
					Err(None) => seen.repository_id
				}
				issues_url = Env.var!("ISSUES_URL").map_err(|_| Fault("the setting ISSUES_URL is missing"))?
				body = Identity.changed_json(Identity.changed(target.name, bound), issues_url)
				Ok(Stop(Response.from_bytes(403, "application/problem+json", body.to_utf8())))
			}
		}
	}

	IdentityInput : { u : I64, same : Bool, old : Try(Identity.Row, [None]), change : Identity.Change, now : U64, claims : Try(Str, [None]) }

	## R-TP18 row 3: the row is `moved` and the request name is the current name, so the batch has the rename-back statements.
	rename_back_applies : IngestRoutes.IdentityInput -> Bool
	rename_back_applies = |input| match input.old {
		Ok(old) => input.same and old.state == Moved and input.change.row.state == Moved
		Err(None) => Bool.False
	}

	## R-TP9, R-TP10, R-TP13, R-TP18, R-TP19 (C2 to C4): the statements of the identity, before the label read. The rows are `INSERT ... SELECT ... WHERE`, never `OR IGNORE` (Q86).
	## The events have `WHERE changes() > 0`: an event only when the statement before it changed a row (Q262, Q266).
	identity_stmts : IngestRoutes.IdentityInput -> List(Sql.Stmt)
	identity_stmts = |input| {
		row = input.change.row
		match input.old {
			Err(None) => new_name_stmts(input)
			Ok(old) => {
				changed = if (input.change.events.is_empty()) [] else [update_stmt(old, row)].concat(input.change.events.map(|e| event_stmt(e, input.now, input.claims)))
				found = if (input.change.events.any(|e| e.action == Found)) [found_stmt(input.u, input.now)] else []
				back = if (rename_back_applies(input)) rename_back_stmts(input) else []
				changed.concat(found).concat(back)
			}
		}
	}

	## R-TP5, R-TP10, R-TP18 rows 2, 5, 6: `U` has no row. The lookup by `repository_id` is SQL, because R-AP41 allows no D1 call between the GitHub read and the batch.
	## When `F` is `U`: the rows of the id that are not `moved` become `moved` (event `rename`), and the event of `U` is `rename` if the batch marked a row, else `bind`.
	new_name_stmts : IngestRoutes.IdentityInput -> List(Sql.Stmt)
	new_name_stmts = |input| {
		row = input.change.row
		insert = Sql.stmt(
			"INSERT INTO repos (repo, repository_id, repository_owner_id, state, successor, state_at, time) SELECT ?1, ?2, ?3, 0, NULL, ?4, ?4 WHERE NOT EXISTS (SELECT 1 FROM repos WHERE repo = ?1)",
			(input.u, row.repository_id, row.owner_id, row.time),
		)
		checks = Sql.stmt(
			"INSERT INTO repo_checks (repo, etag, checked_at, next_check_at, fail_count, app_installed) SELECT ?1, NULL, NULL, ?2, 0, 0 WHERE NOT EXISTS (SELECT 1 FROM repo_checks WHERE repo = ?1)",
			(input.u, input.now + Reads.interval_ms(Bool.False)),
		)
		first_event = input.change.events.map(|e| event_stmt(e, input.now, input.claims))
		if input.same {
			mark = Sql.stmt(
				"UPDATE repos SET state = 2, successor = ?1, state_at = ?2 WHERE repository_id = ?3 AND repo <> ?1 AND state <> 2 AND NOT EXISTS (SELECT 1 FROM repos WHERE repo = ?1)",
				(input.u, input.now, row.repository_id),
			)
			named = Sql.stmt(
				"${event_cols} SELECT ?1, (SELECT COALESCE(MAX(seq), 0) + 1 FROM repo_events WHERE repo = ?1), CASE WHEN EXISTS (SELECT 1 FROM repos WHERE repository_id = ?2 AND repo <> ?1 AND state = 2 AND successor = ?1 AND state_at = ?4) THEN 2 ELSE 0 END, NULL, ?2, NULL, ?3, NULL, ?5, ?4 WHERE changes() > 0",
				(input.u, row.repository_id, row.owner_id, input.now, Sql.or_null(input.claims)),
			)
			[mark, marked_events_stmt(input.u, row.repository_id, input.now, input.claims), insert, named, checks]
		} else {
			[insert].concat(first_event).append(checks)
		}
	}

	## R-TP18 row 3 (C3), Q261: `U` is `moved` and `F` is `U`. (a) the other rows of the id that are not `moved` become `moved`; (b) `U` is `active` again.
	## (a) comes before (b), because it reads whether `U` is `moved`.
	rename_back_stmts : IngestRoutes.IdentityInput -> List(Sql.Stmt)
	rename_back_stmts = |input| {
		row = input.change.row
		mark = Sql.stmt(
			"UPDATE repos SET state = 2, successor = ?1, state_at = ?2 WHERE repository_id = ?3 AND repo <> ?1 AND state <> 2 AND EXISTS (SELECT 1 FROM repos WHERE repo = ?1 AND state = 2 AND repository_id = ?3)",
			(input.u, input.now, row.repository_id),
		)
		revive = Sql.stmt(
			"UPDATE repos SET state = 0, successor = NULL, state_at = ?2 WHERE repo = ?1 AND state = 2 AND repository_id = ?3",
			(input.u, input.now, row.repository_id),
		)
		revived_event = event_stmt(
			{
				repo: input.u,
				action: Rename,
				repository_id_before: Ok(row.repository_id),
				repository_id_after: Ok(row.repository_id),
				owner_id_before: Ok(row.owner_id),
				owner_id_after: Ok(row.owner_id),
				successor: Err(None),
			},
			input.now,
			input.claims,
		)
		[mark, marked_events_stmt(input.u, row.repository_id, input.now, input.claims), revive, revived_event]
	}

	event_cols : Str
	event_cols = "INSERT INTO repo_events (repo, seq, action, repository_id_before, repository_id_after, owner_id_before, owner_id_after, successor, claims, time)"

	## One event row of the change of a row: `seq` is the next number of the repo.
	event_stmt : Identity.Event, U64, Try(Str, [None]) -> Sql.Stmt
	event_stmt = |e, now, claims| Sql.stmt(
		"${event_cols} SELECT ?1, (SELECT COALESCE(MAX(seq), 0) + 1 FROM repo_events WHERE repo = ?1), ?2, ?3, ?4, ?5, ?6, ?7, ?9, ?8 WHERE changes() > 0",
		(
			e.repo,
			Identity.action_code(e.action),
			Sql.or_null(e.repository_id_before),
			Sql.or_null(e.repository_id_after),
			Sql.or_null(e.owner_id_before),
			Sql.or_null(e.owner_id_after),
			Sql.or_null(e.successor),
			now,
			Sql.or_null(claims),
		),
	)

	## The events `rename` of the rows that the statement before it marked `moved` (the successor `u` and `state_at` = `now` find them).
	marked_events_stmt : I64, U64, U64, Try(Str, [None]) -> Sql.Stmt
	marked_events_stmt = |u, id, now, claims| Sql.stmt(
		"${event_cols} SELECT r.repo, (SELECT COALESCE(MAX(seq), 0) + 1 FROM repo_events e WHERE e.repo = r.repo), 2, r.repository_id, r.repository_id, r.repository_owner_id, r.repository_owner_id, ?1, ?4, ?2 FROM repos r WHERE r.repository_id = ?3 AND r.repo <> ?1 AND r.state = 2 AND r.successor = ?1 AND r.state_at = ?2 AND changes() > 0",
		(u, now, id, Sql.or_null(claims)),
	)

	## R-TP9 rows 2 and 3, R-TP11: the new ids, state and successor of the row. The old ids are in `WHERE`, so a row that another request changed is not overwritten (Q262).
	## `time` never changes (C5).
	update_stmt : Identity.Row, Identity.Row -> Sql.Stmt
	update_stmt = |old, row| Sql.stmt(
		"UPDATE repos SET repository_id = ?1, repository_owner_id = ?2, state = ?3, successor = ?4, state_at = ?5 WHERE repo = ?6 AND repository_id = ?7 AND repository_owner_id = ?8",
		(row.repository_id, row.owner_id, Identity.state_code(row.state), Sql.or_null(row.successor), row.state_at, row.repo, old.repository_id, old.owner_id),
	)

	## R-TP19 (C4), Q264: after the event `found`, the next reconcile is not later than now. The code does not touch `releases.withdrawn`.
	found_stmt : I64, U64 -> Sql.Stmt
	found_stmt = |u, now| Sql.stmt("UPDATE repo_checks SET next_check_at = MIN(next_check_at, ?2) WHERE repo = ?1 AND changes() > 0", (u, now))

	# ---- the write batch (slice file section 3.2, R-SG8, Design Q86: no OR IGNORE) ----

	## `via` and `claims` are the code and the claims of the provenance row: 3 and `Err(None)` for an ingest, 0 and the claims text for a publish.
	writes_of : Ingest.Plan, U8, Try(Str, [None]) -> List(Sql.Stmt)
	writes_of = |plan, via, claims| {
		a = plan.artifact
		r = plan.release
		names = plan.names.map(
			|n| {
				sql = "INSERT INTO names (id, kind, value) VALUES (?, ?, ?) ON CONFLICT (kind, value) DO NOTHING"
				if (n.kind == 1) Sql.stmt(sql, (n.id, n.kind, Sql.blob(n.value))) else Sql.stmt(sql, (n.id, n.kind, Str.from_utf8_lossy(n.value)))
			},
		)
		new_targets = plan.new_targets.map(|name| Sql.stmt("INSERT INTO targets (target, name) SELECT (SELECT MAX(target) + 1 FROM targets), ?1 WHERE NOT EXISTS (SELECT 1 FROM targets WHERE name = ?1)", [name]))
		artifact = Sql.stmt(
			"INSERT INTO artifacts (artifact, kind, exposes, platform, roc_pin, size) SELECT ?1, ?2, ?3, ?4, ?5, ?6 WHERE NOT EXISTS (SELECT 1 FROM artifacts WHERE artifact = ?1)",
			(a.id, a.kind, a.exposes_json, Sql.or_null(a.platform_id), Sql.or_null(a.roc_pin), a.size),
		)
		deps = plan.deps.map(
			|d| Sql.stmt(
				"INSERT INTO deps (artifact, alias, dep, form, version, version_text, url, platform) SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8 WHERE NOT EXISTS (SELECT 1 FROM deps WHERE artifact = ?1 AND alias = ?2)",
				(a.id, d.alias, d.dep, Sql.or_null(d.form), Sql.or_null(d.version.map_ok(|c| c.version)), Sql.or_null(d.version.map_ok(|c| c.version_text)), d.url, if (d.is_platform) 1 else 0),
			),
		)
		artifact_targets = plan.target_names.map(
			|name| Sql.stmt(
				"INSERT INTO artifact_targets (artifact, target) SELECT ?1, t.target FROM targets t WHERE t.name = ?2 AND NOT EXISTS (SELECT 1 FROM artifact_targets x WHERE x.artifact = ?1 AND x.target = t.target)",
				(a.id, name),
			),
		)
		label = "form = ?1 AND version = ?2 AND version_text = ?3"
		leaf = Sql.stmt(
			"INSERT INTO log (idx, grp, version, hash, time) SELECT (SELECT COALESCE(MAX(idx), 0) + 1 FROM log), ?4, ?5, ?6, ?7 WHERE NOT EXISTS (SELECT 1 FROM releases WHERE ${label})",
			(r.form, r.column.version, r.column.version_text, plan.leaf.grp, plan.leaf.version, plan.leaf.hash, plan.leaf.time),
		)
		release = Sql.stmt(
			"INSERT INTO releases (log_index, form, version, version_text, artifact, repo, url, tag, roc_version, published_at, yanked, withdrawn, withdrawn_at) SELECT (SELECT MAX(idx) FROM log), ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 0, NULL, NULL WHERE NOT EXISTS (SELECT 1 FROM releases WHERE ${label} AND artifact = ?4)",
			(r.form, r.column.version, r.column.version_text, r.artifact, r.repo, r.url, r.tag, Sql.or_null(r.roc_version), r.published_at),
		)
		provenance = Sql.stmt(
			"INSERT INTO provenance (release, via, claims, time) SELECT r.log_index, ?5, ?6, ?4 FROM releases r WHERE ${label} AND NOT EXISTS (SELECT 1 FROM provenance p WHERE p.release = r.log_index AND p.via = ?5)",
			(r.form, r.column.version, r.column.version_text, plan.provenance_time, via, Sql.or_null(claims)),
		)
		names.concat(new_targets).append(artifact).concat(deps).concat(artifact_targets).concat([leaf, release, provenance])
	}

	db = D1.binding("DB")

	fault = |e| Fault(Str.inspect(e))

	bad_row : [BadRow(Str)] -> IngestRoutes.Error
	bad_row = |e| match e {
		BadRow(text) => Fault(text)
	}
}
