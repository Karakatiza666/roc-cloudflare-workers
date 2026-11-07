## The handler of `POST /v1/compat`, the bot path (Registry R-AP10, R-AP41, R-AP46, R-AP48, R-MX4, R-MX5, R-MX8 to R-MX10; slice 115a). The decisions are in `lib/Compat.roc` (pure, W0).
## The tests are W2: `worker/tests/cases/compat/`. The SQL of the bot set is `sql/compat/*.sql` in this dir (W1: `sql/tests/cases/compat/`).
## The flow (the slice file section 3.3):
## 1. `req.bytes_with!({ max_bytes: Compat.body_limit })`. `Err(TooLarge)`: the 413 answer of `Compat.too_large("body", Compat.body_limit)`. Another `Err`: the bytes `[]` (then 400).
## 2. `Compat.request_kind` of the headers `authorization` and `talon-contributor`. `Refuse(problem)` is the answer (400, R-CT1). `Hint` is the user path of slice 116: `HintRoutes.post!(req, bytes)` (`worker/HintRoutes.roc`).
##    `Bot` goes on. (The bot path reads the body before the token check: R-AP48 rows 4 to 6 come before the route, R-AP66 checks 1 to 7, Design Q144. The media type of a body is a header: a body that is too large and not JSON is 415, `Route.decide` gives it before this handler.)
## 3. `Compat.parse_post(bytes)`. `Err(Bad(problem))`: `Err(Refuse(problem))`. `Err(TooLarge(problem, extra))`: `Ok` of the 413 answer
##    `Response.from_bytes(413, "application/problem+json", Problem.to_json_with(problem, extra).to_utf8())`. No D1 call before this step.
## 4. `Auth.bot!(req)` (slice 108). `Err(problem)` is the answer (401, 403, 500, 502), no D1 call.
## 5. D1 call 1: one `batch!` of 3 statements on the primary: `artifacts`, `targets` and `artifact_targets` for the lists of `Compat.read_params(post)`. `Compat.plan`: `Err(problem)` is the
##    answer (404, 400). A body with no row skips this call and step 6 writes only the sweep.
## 6. D1 call 2: one `batch!` of the row statement (`Compat.rows_sql()`, if there are rows) and the sweep statement (`Compat.sweep_sql()`, if the body has a sweep), with `Time.now_ms!()` once.
##    `written` is the `changes` of the row statement (no trigger fires on `compat`). On a `Constraint` error `Compat.failure_of`: `Bad(problem)` is the answer; `Fault(text)` is `Err(Fault)`;
##    `SweepIncomplete` goes to step 7.
## 7. D1 call 3 on the primary (only after `SweepIncomplete`, R-AP41 "error detail", R-AP66 check 10): the statement `missing` of `sql/compat/` with the sweep as parameters, the state after the
##    rollback; `Compat.sweep_incomplete` is the 422 answer, also for an empty list.
## 8. 201 or 200 by `Compat.written_status`, `content-type: application/json`, `cache-control: no-store`, the body `Compat.written_body(written)`.
import pf.Request
import pf.Response
import pf.D1
import pf.Sql
import pf.Time
import lib.Compat
import lib.Problem
import lib.Reads
import Auth
import ReadRoutes
import HintRoutes
import "sql/compat/prefix.sql" as prefix_sql : Str
import "sql/compat/missing.sql" as missing_sql : Str

CompatRoutes :: [].{

	db = D1.binding("DB")

	post! : Request => Try(Response, ReadRoutes.Error)
	post! = |req| {
		bytes = match req.bytes_with!({ max_bytes: Compat.body_limit }) {
			Ok(found) => Ok(found)
			Err(TooLarge) => Err(Compat.too_large("body", Compat.body_limit))
			Err(BodyErr(_)) => Ok([])
		}
		match Compat.request_kind({ authorization: req.header("authorization"), contributor: req.header("talon-contributor") }) {
			Refuse(problem) => return Err(Refuse(problem))
			Hint => return HintRoutes.post!(req, bytes)
			Bot => {}
		}
		parsed = match bytes {
			Ok(found) => Compat.parse_post(found)
			Err(rejected) => Err(rejected)
		}
		match parsed {
			Err(Bad(problem)) => Err(Refuse(problem))
			Err(TooLarge(problem, extra)) => Ok(Response.from_bytes(413, "application/problem+json", Problem.to_json_with(problem, extra).to_utf8()))
			Ok(post) => {
				_ = Auth.bot!(req).map_err(|problem| Refuse(problem))?
				plan = plan!(post)?
				write!(post, plan)
			}
		}
	}

	## D1 call 1 (skipped when the body has no row): the facts of the artifacts and targets, then `Compat.plan`.
	plan! : Compat.Post => Try(List(Compat.PlanRow), ReadRoutes.Error)
	plan! = |post| {
		if post.rows.is_empty() {
			Ok([])
		} else {
			params = Compat.read_params(post)
			stmts = [
				Sql.stmt("SELECT CAST(artifact AS TEXT) AS artifact, kind FROM artifacts WHERE artifact IN (SELECT CAST(value AS INTEGER) FROM json_each(?1))", [params.artifacts_json]),
				Sql.stmt("SELECT name, target FROM targets WHERE name IN (SELECT value FROM json_each(?1))", [params.targets_json]),
				Sql.stmt("SELECT CAST(artifact AS TEXT) AS artifact, target FROM artifact_targets WHERE artifact IN (SELECT CAST(value AS INTEGER) FROM json_each(?1))", [params.artifacts_json]),
			]
			results = db.batch!(stmts).map_err(|e| Fault(Str.inspect(e)))?
			facts = match results {
				[art, tgt, plat] => {
					artifacts : List(Compat.ArtifactFact)
					artifacts = all(art)?
					target_rows : List(Compat.TargetFact)
					target_rows = all(tgt)?
					platform_targets : List(Compat.PlatformFact)
					platform_targets = all(plat)?
					Ok({ artifacts, target_rows, platform_targets })
				}
				_ => Err(Fault("compat: the read batch gave ${results.len().to_str()} results, not 3"))
			}?
			Compat.plan(post, facts).map_err(|problem| Refuse(problem))
		}
	}

	## D1 call 2: the rows and the sweep in one batch. A failed sweep rolls the rows back (R-MX9).
	write! : Compat.Post, List(Compat.PlanRow) => Try(Response, ReadRoutes.Error)
	write! = |post, plan| {
		now = Time.now_ms!()
		row_stmts = if (plan.is_empty()) [] else [Sql.stmt(Compat.rows_sql(), (Compat.rows_json(plan), now))]
		sweep_stmts = match post.sweep {
			Ok(sweep) => [Sql.stmt(Compat.sweep_sql(), (sweep.nightly, 0.I64, sweep.upto_log_index, now))]
			Err(None) => []
		}
		written = match db.batch!(row_stmts.concat(sweep_stmts)) {
			Ok(results) => match (plan.is_empty(), results) {
				(Bool.False, [first, ..]) => first.info().changes
				_ => 0
			}
			Err(Constraint(c)) => return failed!(post, Compat.failure_of(c))
			Err(Infra(e)) => return Err(Fault(Str.inspect(e)))
		}
		Ok(Response.from_bytes(Compat.written_status(written), "application/json", Compat.written_body(written).to_utf8()).with_header("cache-control", "no-store"))
	}

	## A failed write batch: a problem, a fault, or (D1 call 3 on the primary, the state after the rollback) the 422 with the members that have no bot row.
	failed! : Compat.Post, [SweepIncomplete, Bad(Problem), Fault(Str)] => Try(Response, ReadRoutes.Error)
	failed! = |post, failure| match failure {
		Bad(problem) => Err(Refuse(problem))
		Fault(text) => Err(Fault(text))
		SweepIncomplete => match post.sweep {
			Err(None) => Err(Fault("a sweep-incomplete error, but the body has no sweep"))
			Ok(sweep) => {
				rows : Try(List({ hash : List(U8) }), _)
				rows = db.all!("${prefix_sql}\n${missing_sql}", (sweep.nightly, 0.I64, sweep.upto_log_index))
				found = rows.map_err(|e| Fault(Str.inspect(e)))?
				missing = found.map_try(|r| Reads.base58_of_bytes(r.hash)).map_err(|_| Fault("a member hash is not 32 bytes"))?
				Err(Refuse(Compat.sweep_incomplete({ tag: sweep.tag, upto_log_index: sweep.upto_log_index, missing })))
			}
		}
	}

	all = |result| result.all().map_err(|e| Fault(Str.inspect(e)))
}
