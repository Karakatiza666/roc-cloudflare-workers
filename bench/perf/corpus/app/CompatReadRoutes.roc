## The handlers of `GET /v1/sweeps/{tag}`, `GET /v1/compat_hints` and `GET /v1/artifacts/{hash}/compat` (Registry R-AP4, R-AP39, R-AP40, R-AP41, R-AP43, R-AP54 to R-AP56; slice 115b).
## The decisions are in `lib/CompatReads.roc` (pure, W0). The tests are W2: `worker/tests/cases/compat/`. The SQL is `sql/compat/*.sql` in this dir (W1: `sql/tests/cases/compat/`).
## The flow (the slice file section 3):
## `sweep!`: `CompatReads.parse_sweep_target(req.query("target"))` (400, no D1 call); `Id.nightly_id(tag)`, `Err` is 404 `CompatReads.no_tag(tag)` (no D1 call); one batch (one session,
##   `Reads.session_of(talon-bookmark)`): the `toolchains` tag of the nightly, the `sweeps` row, `log_size`, the count of members, the missing hashes; no `toolchains` row is 404; 200,
##   `no-store`, `CompatReads.sweep_body`. No ETag, no Cache API.
## `audit!`: `CompatReads.parse_audit(req.query("audit"))` (400, no D1 call); then the read mechanism of the read routes (`ReadRoutes.serve!` with `CompatReads.cache_control`):
##   the Cache API, the ETag and 304, one session and one statement; `CompatReads.pairs_body`.
## `artifact_compat!`: `Reads.artifact_id(hash)`, `Err(BadHash)` is 404 `Reads.no_artifact(hash)` with no D1 call; `ReadRoutes.serve!` with `CompatReads.cache_control`; one batch: the
##   artifact row (no row: 404 `Reads.no_artifact`, not put in the Cache API), `runs`, `hints`; `CompatReads.compat_body`.
import pf.Request
import pf.Response
import pf.D1
import pf.Sql
import records.Id
import lib.ClosureQuery
import lib.CompatReads
import lib.Reads
import ReadRoutes
import "sql/compat/prefix.sql" as prefix_sql : Str
import "sql/compat/members.sql" as members_sql : Str
import "sql/compat/missing.sql" as missing_sql : Str
import "sql/compat/audit.sql" as audit_sql : Str
import "sql/compat/sweep_tag.sql" as sweep_tag_sql : Str
import "sql/compat/sweep_row.sql" as sweep_row_sql : Str
import "sql/compat/log_size.sql" as log_size_sql : Str
import "sql/compat/artifact_present.sql" as present_sql : Str
import "sql/compat/artifact_runs.sql" as runs_sql : Str
import "sql/compat/artifact_hints.sql" as hints_sql : Str

CompatReadRoutes :: [].{

	db = D1.binding("DB")

	## `GET /v1/sweeps/{tag}` (R-AP39): one session, one batch of 5 statements. No ETag and no Cache API.
	sweep! : Request, Str => Try(Response, ReadRoutes.Error)
	sweep! = |req, tag| {
		CompatReads.parse_sweep_target(req.query("target")).map_err(|problem| Refuse(problem))?
		nightly = Id.nightly_id(tag).map_err(|_| Refuse(CompatReads.no_tag(tag)))?
		bound = (nightly, 0.I64, Sql.null)
		stmts = [
			Sql.stmt(sweep_tag_sql, [nightly]),
			Sql.stmt(sweep_row_sql, [nightly]),
			Sql.stmt(log_size_sql, Sql.none),
			Sql.stmt("${prefix_sql}\n${members_sql}", bound),
			Sql.stmt("${prefix_sql}\n${missing_sql}", bound),
		]
		session = db.with_session!(Reads.session_of(req.header("talon-bookmark"))).map_err(|e| Fault(Str.inspect(e)))?
		results = session.batch!(stmts).map_err(|e| Fault(Str.inspect(e)))?
		body = sweep_answer(results, tag)?
		Ok(Response.from_bytes(200, "application/json", body.to_utf8()).with_header("cache-control", CompatReads.sweep_cache_control))
	}

	sweep_answer : List(D1.Result), Str -> Try(Str, ReadRoutes.Error)
	sweep_answer = |results, tag| match results {
		[tags, sweeps, sizes, counts, missing] => {
			tag_rows : List({ tag : Str })
			tag_rows = all(tags)?
			stored = match tag_rows {
				[one, ..] => one.tag
				[] => return Err(Refuse(CompatReads.no_tag(tag)))
			}
			sweep_rows : List(CompatReads.SweepRow)
			sweep_rows = all(sweeps)?
			size_rows : List({ log_size : U64 })
			size_rows = all(sizes)?
			count_rows : List({ members : U64 })
			count_rows = all(counts)?
			missing_rows : List({ hash : List(U8) })
			missing_rows = all(missing)?
			hashes = missing_rows.map_try(|r| Reads.base58_of_bytes(r.hash)).map_err(bad_row)?
			Ok(
				CompatReads.sweep_body({
					tag: stored,
					sweep: match sweep_rows {
						[one, ..] => Ok(one)
						[] => Err(None)
					},
					log_size: match size_rows {
						[one, ..] => one.log_size
						[] => 0
					},
					members: match count_rows {
						[one, ..] => one.members
						[] => 0
					},
					missing: hashes,
				}),
			)
		}
		_ => Err(Fault("sweeps: the batch gave ${results.len().to_str()} results, not 5"))
	}

	## `GET /v1/compat_hints?audit=n` (R-AP40): the read mechanism of the read routes, one statement.
	audit! : Request => Try(Response, ReadRoutes.Error)
	audit! = |req| {
		limit = CompatReads.parse_audit(req.query("audit")).map_err(|problem| Refuse(problem))?
		ReadRoutes.serve!(req, CompatReads.cache_control, [Sql.stmt(audit_sql, [limit])], |results, _now| audit_answer(results))
	}

	audit_answer : List(D1.Result) -> Try(Str, ReadRoutes.Error)
	audit_answer = |results| match results {
		[one] => {
			rows : List(CompatReads.PairRow)
			rows = all(one)?
			CompatReads.pairs_body(rows).map_err(bad_row)
		}
		_ => Err(Fault("compat_hints: the batch gave ${results.len().to_str()} results, not 1"))
	}

	## `GET /v1/artifacts/{hash}/compat` (R-AP4): a malformed hash is 404 with no D1 call.
	artifact_compat! : Request, Str => Try(Response, ReadRoutes.Error)
	artifact_compat! = |req, hash| match Reads.artifact_id(hash) {
		Err(BadHash) => Err(Refuse(Reads.no_artifact(hash)))
		Ok(id) => {
			stmts = [Sql.stmt(present_sql, [id]), Sql.stmt(runs_sql, [id]), Sql.stmt(hints_sql, [id])]
			ReadRoutes.serve!(req, CompatReads.cache_control, stmts, |results, _now| compat_answer(results, hash))
		}
	}

	compat_answer : List(D1.Result), Str -> Try(Str, ReadRoutes.Error)
	compat_answer = |results, hash| match results {
		[present, runs, hints] => {
			found : List({ present : I64 })
			found = all(present)?
			if found.is_empty() {
				Err(Refuse(Reads.no_artifact(hash)))
			} else {
				run_rows : List(ClosureQuery.RunRow)
				run_rows = all(runs)?
				hint_rows : List(ClosureQuery.HintRow)
				hint_rows = all(hints)?
				CompatReads.compat_body({ runs: run_rows, hints: hint_rows }).map_err(bad_row)
			}
		}
		_ => Err(Fault("artifact compat: the batch gave ${results.len().to_str()} results, not 3"))
	}

	all = |result| result.all().map_err(|e| Fault(Str.inspect(e)))

	bad_row : [BadRow(Str)] -> ReadRoutes.Error
	bad_row = |e| match e {
		BadRow(text) => Fault(text)
	}
}
