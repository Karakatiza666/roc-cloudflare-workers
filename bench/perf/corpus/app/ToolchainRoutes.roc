## The handlers of the toolchain routes (Registry 4: R-AP5, R-AP6, R-AP41, R-AP47; 7: R-PU7 to R-PU10; slice 109). The decisions are in `lib/Toolchains.roc` (pure, W0).
## This module only orders the effects. The tests are W2: `worker/tests/cases/toolchains/`. Each handler gives `Err(Refuse(problem))` for the answers that are problems
## (400, 404, 422, 502): `main.roc` turns it into the problem answer. `Err(Fault(text))` is a fault of the Worker: 500 `internal` (R-AP48, never a `crash`).
##
## `put!` flow (R-AP57, R-AP80, R-AP6, R-PU7 to R-PU10; the bot check of R-TP7 is done by `main.roc` with `Auth.bot!` before this function; no D1 call and no GitHub call before it):
## 1. `Id.nightly_id(tag)` of `records` (R-IK4), then `Toolchains.start`. `Refuse` is 422 `not-a-candidate` with no D1 call and no GitHub call.
## 2. D1 call 1: `SELECT tag, target, asset_name, sha256, size, published_at, log_index FROM toolchains WHERE nightly = ? ORDER BY log_index` (the nightly id bound as text, R-IK2).
##    `Toolchains.after_rows(tag, rows)`: `Answer(rows)` is 200 with `Toolchains.put_body(rows)` and no GitHub call (R-PU9, R-PU10); `Refuse` is 422 (R-IK4); `ReadGithub` goes on.
## 3. One `GET` of `Toolchains.release_url(tag)`, with the headers `User-Agent` and `Accept: application/vnd.github+json` (GitHub refuses a call with no `User-Agent`).
##    Status 404 is 404 `Toolchains.no_release(tag)`. A status other than 200 is `Toolchains.github_status(status)`. No answer is `Toolchains.github_no_answer`.
##    A body that `Toolchains.parse_release` refuses (steps 4 and 5: also a `published_at` that is not in the `Z` form) is `Toolchains.github_bad`. All are `Refuse`.
## 4. `Toolchains.candidates(tag, release)`: a draft or a prerelease, or no asset left, is 422 `Refuse` with no D1 call (steps 4 and 6).
## 5. D1 call 2: one `batch!` with, for each `Write` of `Toolchains.writes_of` (the clock `Time.now_ms!` once for the whole request), the leaf statement and the `toolchains`
##    statement of R-SG8 row 6 (no `OR IGNORE`, the `MAX` in a subquery), and a last statement that reads the rows of step 2 for the nightly.
##    The status is `Toolchains.put_status(<the changes of each toolchains statement>)`: 201, or 200 when the batch wrote nothing (another request was first). The body is
##    `Toolchains.put_body` of the rows of the last statement. A `Constraint` failure of the batch is `Fault`.
## The answers 200 and 201 have `content-type: application/json` and `cache-control: no-store` (R-AP6).
##
## `list!` flow (R-AP5, R-AP54, R-AP55, R-AP56): `Toolchains.parse_query` of the query parameters `after` and `target` first (a 400 makes no D1 call). Then the read mechanism of the read
## routes of slice 106 (the Cache API of R-AP43 with the whole URL as the key, the session and `Talon-Bookmark` of R-AP41 row 5, the ETag and the 304 of R-AP54), with `Toolchains.cache_control`.
## D1 call 1 (a statement): the rows with `log_index > after`, and `target = ?` when the filter is there, `ORDER BY log_index LIMIT 1001`. `Toolchains.page_of` and
## `Toolchains.page_body` make the body. A `target` with no row (empty, unknown) is 200 with no rows.
import pf.Request
import pf.Response
import GithubRead
import lib.GithubApp
import pf.D1
import pf.Sql
import pf.Cache
import pf.Time
import lib.Problem
import lib.Reads
import lib.Toolchains
import records.Id

ToolchainRoutes :: [].{

	## The error of a handler: the same form as `ReadRoutes.Error`.
	Error : [Refuse(Problem), Fault(Str)]

	db = D1.binding("DB")

	## The columns of a `Toolchains.Row`, in the order of the type.
	columns : Str
	columns = "tag, target, asset_name, sha256, size, published_at, log_index"

	## `PUT /v1/toolchains/{tag}` (R-AP6): 201 with the new rows, 200 for a tag that has rows.
	put! : Request, Str => Try(Response, ToolchainRoutes.Error)
	put! = |_req, tag| {
		nightly = match Toolchains.start(tag, Id.nightly_id(tag)) {
			Refuse(problem) => return Err(Refuse(problem))
			ReadRows(id) => id
		}
		rows = read_rows!(nightly)?
		match Toolchains.after_rows(tag, rows) {
			Answer(found) => Ok(json_answer(200, Toolchains.put_body(found)))
			Refuse(problem) => Err(Refuse(problem))
			ReadGithub => publish!(tag, nightly)
		}
	}

	## D1 call 1 (R-AP57 step 2): the rows of the nightly id, in `log_index` order.
	read_rows! : I64 => Try(List(Toolchains.Row), ToolchainRoutes.Error)
	read_rows! = |nightly| {
		rows : Try(List(Toolchains.Row), _)
		rows = db.all!("SELECT ${columns} FROM toolchains WHERE nightly = ? ORDER BY log_index", [nightly])
		rows.map_err(|e| Fault(Str.inspect(e)))
	}

	## R-AP57 steps 3 to 7 for a tag with no row: the GitHub read, the assets, and the one batch.
	publish! : Str, I64 => Try(Response, ToolchainRoutes.Error)
	publish! = |tag, nightly| {
		release = read_release!(tag)?
		picked = Toolchains.candidates(tag, release).map_err(|problem| Refuse(problem))?
		writes = Toolchains.writes_of({ tag, nightly, published_at: release.published_at, now_ms: Time.now_ms!(), picked })
		statements = writes.join_map(statements_of).append(Sql.stmt("SELECT ${columns} FROM toolchains WHERE nightly = ? ORDER BY log_index", [nightly]))
		results = db.batch!(statements).map_err(|e| Fault(Str.inspect(e)))?
		changes = toolchain_changes(results.take_first(2 * writes.len()))
		last = results.last().map_err(|_| Fault("the batch gave no result"))?
		rows : Try(List(Toolchains.Row), _)
		rows = last.all()
		found = rows.map_err(|e| Fault(Str.inspect(e)))?
		Ok(json_answer(Toolchains.put_status(changes), Toolchains.put_body(found)))
	}

	## R-AP57 step 3: one `GET` of the release. Each fault is a problem.
	read_release! : Str => Try(Toolchains.Release, ToolchainRoutes.Error)
	read_release! = |tag| {
		res = match GithubRead.send!(Request.get(Toolchains.release_url(tag))) {
			Ok(found) => found
			Err(NoAnswer) => return Err(Refuse(Toolchains.github_no_answer))
			Err(Token(failure)) => return Err(token_error(failure))
		}
		status = res.status()
		if status == 404 {
			Err(Refuse(Toolchains.no_release(tag)))
		} else if status != 200 {
			Err(Refuse(Toolchains.github_status(status)))
		} else {
			text = res.text!().map_err(|_| Refuse(Toolchains.github_bad))?
			Toolchains.parse_release(text).map_err(|_| Refuse(Toolchains.github_bad))
		}
	}

	## R-PU25, Q4: a setting or sign fault is 500 `internal` (`Fault`), a failed token request is 502 `upstream`.
	token_error : GithubApp.Failure -> ToolchainRoutes.Error
	token_error = |failure| match GithubApp.failure_class(failure) {
		Upstream(detail) => Refuse(Problem.new(Upstream, detail))
		Fault(text) => Fault(text)
	}

	## R-SG8 row 6: the leaf statement, then the `toolchains` statement, with no `OR IGNORE`.
	statements_of : Toolchains.Write -> List(Sql.Stmt)
	statements_of = |w| [
		Sql.stmt(
			"INSERT INTO log (idx, grp, version, hash, time) SELECT (SELECT COALESCE(MAX(idx), 0) + 1 FROM log), ?, ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM toolchains WHERE nightly = ? AND target = ?)",
			(w.leaf.grp, w.leaf.version, w.leaf.hash, w.leaf.time, w.nightly, w.target),
		),
		Sql.stmt(
			"INSERT INTO toolchains (nightly, target, tag, asset_name, sha256, size, published_at, log_index) SELECT ?, ?, ?, ?, ?, ?, ?, (SELECT MAX(idx) FROM log) WHERE NOT EXISTS (SELECT 1 FROM toolchains WHERE nightly = ? AND target = ?)",
			(w.nightly, w.target, w.tag, w.asset_name, w.sha256, w.size, w.published_at, w.nightly, w.target),
		),
	]

	## The `changes` of the `toolchains` statements: the second result of each pair.
	toolchain_changes : List(D1.Result) -> List(U64)
	toolchain_changes = |results| {
		counted = results.fold({ n: 0.U64, out: [] }, |acc, r| { n: acc.n + 1, out: if (acc.n % 2 == 1) acc.out.append(r.info().changes) else acc.out })
		counted.out
	}

	## A 200 or 201 answer of the PUT: JSON, never cached (R-AP6).
	json_answer : U16, Str -> Response
	json_answer = |status, body| Response.from_bytes(status, "application/json", body.to_utf8()).with_header("cache-control", "no-store")

	## `GET /v1/toolchains?after=&target=` (R-AP5, R-AP47).
	list! : Request => Try(Response, ToolchainRoutes.Error)
	list! = |req| {
		query = Toolchains.parse_query({ after: req.query("after"), target: req.query("target") }).map_err(|problem| Refuse(problem))?
		key = req.url()
		bypass = Reads.bypass_cache({ cache_control: req.header("cache-control"), pragma: req.header("pragma") })
		hit = if (bypass) Err(NotFound) else Cache.default.get!(key).map_err(|_| NotFound)
		answer = match hit {
			Ok(cached) => cached
			Err(NotFound) => fresh!(req, key, query)?
		}
		Ok(conditional(answer, req.header("if-none-match")))
	}

	## A miss or a bypass: D1 call 1, the 200 answer, and the Cache API (R-AP55).
	fresh! : Request, Str, Toolchains.Query => Try(Response, ToolchainRoutes.Error)
	fresh! = |req, key, query| {
		session = db.with_session!(Reads.session_of(req.header("talon-bookmark"))).map_err(|e| Fault(Str.inspect(e)))?
		rows : Try(List(Toolchains.Row), _)
		rows = match query.target {
			Ok(target) => session.all!("SELECT ${columns} FROM toolchains WHERE log_index > ? AND target = ? ORDER BY log_index LIMIT ${limit_text}", (query.after, target))
			Err(None) => session.all!("SELECT ${columns} FROM toolchains WHERE log_index > ? ORDER BY log_index LIMIT ${limit_text}", [query.after])
		}
		found = rows.map_err(|e| Fault(Str.inspect(e)))?
		body = Toolchains.page_body(Toolchains.page_of(found)).to_utf8()
		res = Response.from_bytes(200, "application/json", body)
			.with_header("cache-control", Toolchains.cache_control)
			.with_header("etag", Reads.etag_of(body))
		Ok(Cache.default.put!(key, res) ?? res)
	}

	## The read asks for one more row than the page, to know `more`.
	limit_text : Str
	limit_text = (Toolchains.page_limit + 1).to_str()

	## R-AP54: `If-None-Match` against the `ETag` of the answer. A match is 304 with `ETag` and `Cache-Control`, and no `Content-Type`.
	conditional : Response, Try(Str, [NotFound]) -> Response
	conditional = |answer, if_none_match| match (if_none_match, answer.header("etag")) {
		(Ok(wanted), Ok(etag)) if Reads.etag_matches(wanted, etag) =>
			Response.from_status(304).with_header("etag", etag).with_header("cache-control", Toolchains.cache_control)
		_ => answer
	}
}
