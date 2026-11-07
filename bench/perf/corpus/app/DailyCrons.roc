## The daily cron job (Registry R-CT5, R-CT15, R-PU35, R-PU36; slice 120). The decisions and the SQL texts are in `lib/Daily.roc` (pure, W0). This module only orders the effects.
## The tests are W2: `worker/tests/cases/cron/`. `main.roc` registers it with `Worker.cron(Daily.cron, DailyCrons.run!)`.
##
## Flow (the clock is `Time.now_ms!()` once, Design Q345):
## 1. Hint cleanup: `batch!` or `run!` of `Daily.hints_sql`, then `Daily.days_sql` (bound ?1 = now) on the primary.
## 2. Trim: `Daily.due_sql` (bound ?1 = now) gives the compilers, the oldest first. For each one, in this order: ONE `batch!` of `Daily.trim_sqls` (bound ?1 = the nightly text for each statement).
##    A batch that fails (`Err`) writes ONE log line `Log.warn!("trim failed", { nightly, error })` (a proposal, TW24: no contributor id, no name) and the loop goes on with the next compiler.
##    The batch is atomic, so a failed compiler keeps all its rows and totals; it is due again at the next run (R-PU35).
## The run gives `Ok({})` when each step ran, also when one compiler failed (as R-PU37 row 2). What a failure of step 1 or of the due read does is Design Q344 (slice file): no test until it is answered.
import pf.Worker
import pf.Cbor
import pf.D1
import pf.Log
import pf.Sql
import pf.Time
import lib.Daily

DailyCrons :: [].{

	run! : Worker.Scheduled => Try({}, [Fault(Str)])
	run! = |_s| {
		now = Time.now_ms!()
		step!("hint cleanup failed", Daily.hints_sql(), Sql.none)
		step!("hint days cleanup failed", Daily.days_sql(), [now])
		trim!(now)
		Ok({})
	}

	db = D1.binding("DB")

	## Q344: a failed DELETE is a log line, and the run goes on.
	step! : Str, Str, params => {} where [params.Cbor.Writable]
	step! = |msg, sql, params| {
		match db.run!(sql, params) {
			Ok(_) => {}
			Err(e) => Log.warn!(msg, { error: Str.inspect(e) })
		}
	}

	## R-CT15: the due compilers, the oldest first, one batch for each. A failed read skips the trim (Q344).
	trim! : U64 => {}
	trim! = |now| {
		due : Try(List({ nightly : Str }), _)
		due = db.all!(Daily.due_sql(), [now])
		match due {
			Err(e) => Log.warn!("trim read failed", { error: Str.inspect(e) })
			Ok(rows) => {
				for row in rows {
					nightly = row.nightly
					stmts = Daily.trim_sqls().map(|sql| Sql.stmt(sql, [nightly]))
					match db.batch!(stmts) {
						Ok(_) => {}
						Err(e) => Log.warn!("trim failed", { nightly, error: Str.inspect(e) })
					}
				}
			}
		}
	}
}
