## The handler of `POST /v1/closure` (Registry R-AP3, R-AP16 to R-AP18, R-AP20, R-AP41, R-AP46; slice 110). The decisions are in `lib/ClosureQuery.roc` (pure, W0).
## The tests are W2: `worker/tests/cases/closure/`. The SQL is `sql/closure/*.sql` in this dir (W1: `sql/tests/cases/closure/`).
## The flow (the slice file section 3.3):
## 1. `req.bytes_with!({ max_bytes: ClosureQuery.body_limit })`. `Err(TooLarge)`: the answer of `ClosureQuery.too_large("body", ClosureQuery.body_limit)`. Another `Err`: the bytes `[]`.
## 2. `ClosureQuery.parse(bytes)`. `Err(Bad(problem))`: `Err(Refuse(problem))`. `Err(TooLarge(problem, extra))`: `Ok` of the answer
##    `Response.from_bytes(413, "application/problem+json", Problem.to_json_with(problem, extra).to_utf8())` (`ReadRoutes.Error` has no 413 form).
##    No D1 call before this step (R-AP46: 413 before any D1 call).
## 3. One call: `db.with_session!(Reads.session_of(req.header("talon-bookmark")))`, then one `batch!` of the 12 statements, in the order of the slice file
##    section 4. Each statement is the text of `sql/closure/prefix.sql`, a newline, and the text of `sql/closure/<name>.sql`, with the 4 parameters
##    `(query.groups_json, query.hashes_json, Sql.or_null(query.from), Sql.or_null(query.to))`. A batch is one transaction (R-AP18). The closure changes no state (R-AP20).
## 4. The rows (typed reads of each `D1.Result`) as `ClosureQuery.Rows`, then `ClosureQuery.answer(query, rows, Time.now_ms!())`. `Err(BadRow)`: `Fault` (500).
## 5. 200, `content-type: application/json`, `cache-control: ClosureQuery.cache_control` (`no-store`, R-AP3). No ETag, no Cache API (it is a POST).
import pf.Request
import pf.Response
import pf.D1
import pf.Sql
import pf.Time
import lib.ClosureQuery
import lib.Problem
import lib.Reads
import ReadRoutes
import "sql/closure/prefix.sql" as prefix_sql : Str
import "sql/closure/artifacts.sql" as artifacts_sql : Str
import "sql/closure/deps.sql" as deps_sql : Str
import "sql/closure/targets.sql" as targets_sql : Str
import "sql/closure/releases.sql" as releases_sql : Str
import "sql/closure/unknown.sql" as unknown_sql : Str
import "sql/closure/epochs.sql" as epochs_sql : Str
import "sql/closure/runs.sql" as runs_sql : Str
import "sql/closure/nearest.sql" as nearest_sql : Str
import "sql/closure/hints.sql" as hints_sql : Str
import "sql/closure/checked.sql" as checked_sql : Str
import "sql/closure/repos.sql" as repos_sql : Str
import "sql/closure/log_size.sql" as log_size_sql : Str

ClosureRoute :: [].{

	post! : Request => Try(Response, ReadRoutes.Error)
	post! = |req| {
		parsed = match req.bytes_with!({ max_bytes: ClosureQuery.body_limit }) {
			Ok(bytes) => ClosureQuery.parse(bytes)
			Err(TooLarge) => Err(ClosureQuery.too_large("body", ClosureQuery.body_limit))
			Err(BodyErr(_)) => ClosureQuery.parse([])
		}
		match parsed {
			Err(Bad(problem)) => Err(Refuse(problem))
			Err(TooLarge(problem, extra)) => Ok(Response.from_bytes(413, "application/problem+json", Problem.to_json_with(problem, extra).to_utf8()))
			Ok(query) => {
				params = (query.groups_json, query.hashes_json, Sql.or_null(query.from), Sql.or_null(query.to))
				stmts = statements.map(|body| Sql.stmt("${prefix_sql}\n${body}", params))
				session = db.with_session!(Reads.session_of(req.header("talon-bookmark"))).map_err(|e| Fault(Str.inspect(e)))?
				results = session.batch!(stmts).map_err(|e| Fault(Str.inspect(e)))?
				rows = rows_of(results)?
				body = ClosureQuery.answer(query, rows, Time.now_ms!()).map_err(
					|e| match e {
						BadRow(text) => Fault(text)
					},
				)?
				Ok(Response.from_bytes(200, "application/json", body.to_utf8()).with_header("cache-control", ClosureQuery.cache_control))
			}
		}
	}

	db = D1.binding("DB")

	## The 12 statements of the batch, in the order of the slice file section 4. Each one is run after the text of `prefix.sql`.
	statements : List(Str)
	statements = [artifacts_sql, deps_sql, targets_sql, releases_sql, unknown_sql, epochs_sql, runs_sql, nearest_sql, hints_sql, checked_sql, repos_sql, log_size_sql]

	## The typed rows of each result. A read error is a fault (500).
	rows_of : List(D1.Result) -> Try(ClosureQuery.Rows, ReadRoutes.Error)
	rows_of = |results| match results {
		[art, dep, tgt, rel, unk, epo, run, nea, hin, che, rep, log] => {
			sizes : List({ log_size : U64 })
			sizes = all(log)?
			Ok({
				artifacts: all(art)?,
				deps: all(dep)?,
				target_rows: all(tgt)?,
				releases: all(rel)?,
				unknown: all(unk)?,
				epochs: all(epo)?,
				runs: all(run)?,
				nearest: all(nea)?,
				hints: all(hin)?,
				checked: all(che)?,
				repos: all(rep)?,
				log_size: match sizes {
					[one, ..] => one.log_size
					[] => 0
				},
			})
		}
		_ => Err(Fault("closure: the batch gave ${results.len().to_str()} results, not 12"))
	}

	all = |result| result.all().map_err(|e| Fault(Str.inspect(e)))
}
