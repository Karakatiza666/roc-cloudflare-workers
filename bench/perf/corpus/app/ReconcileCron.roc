## The reconcile cron (Registry R-PU21 to R-PU25, R-PU35 to R-PU37, R-RE14; slice 119b, docs/slices/119-reconcile.md section 3). The decisions are in `lib/Reconcile.roc` (pure, W0).
## The tests are W2: `worker/tests/cases/reconcile/`. `main.roc` registers it with `Worker.cron(Reconcile.cron, ReconcileCron.run!)`.
##
## Flow (the clock is `Time.now_ms!()` once, Design Q345):
## 1. The claim: ONE `db.all!(Reconcile.claim_sql(), (now, Reconcile.max_rows))` on the primary. A failed claim writes `Log.warn!("reconcile claim failed", { error })` and the run ends `Ok({})`.
## 2. Each claimed row, one at a time (Q370: the order), with `interval = Reads.interval_ms(app_installed)`:
##    a. `GithubRead.send!(GET https://api.github.com/repositories/<repository_id>)` (R-PU31, R-TP10). `Webhook.repository_outcome`: `Withdraw` (404, private, internal): ONE batch on the
##       primary with the statements of `IndexQueue.withdraw!` (R-PU24, R-PU33, R-TP11: the row of the current name `missing` and its event, `repo-missing` on the releases of every name of the
##       repository id that have no value) and the pass update of the row (below, with no `etag` change). No list read. `Stale` (public): the `full_name` (`Identity.full_name_of`), go on.
##       `Err(Upstream)`, `NoAnswer`, `Token(_)`, a body with no `full_name`: the row fails.
##    b. `GithubRead.send!(GET Reconcile.list_url(full_name))` with the header `if-none-match: <etag>` when the row has an `etag` (no header when it has none). `Reconcile.list_outcome`.
##       `NotModified` (304): ONE batch with only the pass update (R-PU23: `etag` stays; Design Q374: a 304 is a pass, so `fail_count` = 0 and the interval).
##       `Changed({ etag, list })` (200): `Reconcile.list_work`. When `candidates` is not empty: FIRST `IndexQueue.index.send_batch!` of `Reconcile.message_of(repository_id, id)` for each one
##       (R-PU37 row 5). A failed send: the row fails (nothing of the list is written, the etag is not stored). Then ONE batch: the `changes` (as `IndexQueue.write_changes!` writes them:
##       `UPDATE releases SET withdrawn = ?2, withdrawn_at = <now> WHERE log_index = ?1 AND withdrawn IS NULL`; a clear sets both to NULL) and the pass update with the new `etag`
##       (`NULL` when the answer has none). A failed batch: the row fails (D1 rolls the batch back, so nothing of it stays).
##       `Err(Failed(text))`: the row fails.
##    The pass update: `UPDATE repo_checks SET checked_at = <now>, next_check_at = Reconcile.next_check(now, interval, 0), fail_count = 0 [, etag = ?] WHERE repo = CAST(? AS INTEGER)`.
##    A failed row (R-PU37 rows 2 to 4): ONE batch `UPDATE repo_checks SET fail_count = <n>, next_check_at = Reconcile.next_check(now, interval, n)` with n = the claimed `fail_count` + 1
##    (`checked_at` and `etag` stay), and ONE log line `Log.warn!("reconcile row failed", { job: "reconcile", repository_id, fail_count: n, error })` (no name, R-PU32; the texts are proposals, TW24).
##    The run goes on with the next row.
##    c. R-PU25, Design Q377: after each GitHub answer of the row, `Reconcile.reserve` of its headers. `Ok(at)`: the row still does ALL its work (its list read too, also when the reserve came from the visibility read), then ONE statement moves every claimed row that was not started:
##       `UPDATE repo_checks SET next_check_at = <at> WHERE repo IN (...)` (`fail_count` stays), ONE line `Log.warn!("reconcile rate reserve", { reset_ms: <at>, moved: <the count of rows moved> })`, and the run stops.
## Slice 119c (docs/slices/119-reconcile.md sections 11 and 13; Design Q371, Q372, Q376, Q378 to Q380). Changes to the flow above:
## - a. The visibility read sends `if-none-match: <repo_etag>` when the claim gives one (Q371). A 304: public, the name of the row and the same ids: the list read of the NAME OF THE ROW, no identity
##   write, and the pass keeps `repo_etag`. A 200 public: the pass stores `Reconcile.repo_etag_of(..)`. A withdraw (Q376: `IndexQueue.withdraw_stmts` also sets `etag` and `repo_etag` NULL).
##   A failed row does not change `repo_etag`.
## - Identity, for a 200 public read (in the batch of the row, BEFORE the release changes and the pass; each statement with the SQL guards of slice 113, R-PU36; reuse the identity statements of
##   `IngestRoutes`). `F` = the `full_name` in lower case. (1) `F` is the name of the row: R-TP9 row 2 when `owner.id` is not the `repository_owner_id` of the row (the new owner id, event `transfer`,
##   Q379), then `found` when the row is `missing` (state `active`, event `found`, only when the statement changed the row, Q378). (2) `F` is another name (Q380, R-TP18 rows 1, 3, 4 with U = F):
##   `F` has no row: the `names` row, the `repos` row of `F` (`active`, the ids of the read, `state_at` and `time` now, event `rename` seq 1 with no ids before), the `repo_checks` row of `F`
##   (`app_installed` of the claimed row, `next_check_at` = now + the interval, the rest NULL or 0), and each row of the repository id that is not `moved` gets `moved`, successor `F`, `state_at` now,
##   event `rename`. The row of `F` is `moved` with the same id: R-TP18 row 3. The row of `F` is `active` or `missing` with the same id: (1) on the row of `F`. A row of `F` with ANOTHER
##   `repository_id`: no identity write. The list read is of the `full_name` as GitHub gave it, and the list work is on the releases of every name of the repository id (as 119b).
## - b. Pages (Q372): page 1 with `if-none-match` (a 304 ends the read); while `Reconcile.has_next(link)`, read `Reconcile.page_url(full_name, n)` (no `if-none-match`), at most `Reconcile.max_pages`;
##   a page 10 that still has a next page: the row fails with `the release list has more than 10 pages`. `Reconcile.merge_pages`. More than one page: the pass stores `etag` NULL.
## - The clear of `repo-missing` (R-PU24, Q379) comes from `list_work`. The guard of a clear changes: it is the value that the claim saw, `WHERE log_index = ?1 AND withdrawn = ?2` (R-PU36: a job
##   `privatized` can set `repo-missing` during the run, and that value must stay; test `pu36-state-guard`).
## 3. The result is `Ok({})` when the run ran (R-PU37 row 2: one failed row is a log line, not an `Err`). A trap stops the run; the claim makes the rows due again after 15 min (R-PU37 row 1).
import records.Sorted
import pf.Worker
import pf.D1
import pf.Log
import pf.Request
import pf.Response
import pf.Sql
import pf.Time
import lib.Identity
import lib.Ingest
import lib.Reads
import lib.Reconcile
import lib.Webhook
import GithubRead
import IndexQueue
import IngestRoutes

ReconcileCron :: [].{

	run! : Worker.Scheduled => Try({}, [Fault(Str)])
	run! = |_s| {
		now = Time.now_ms!()
		claimed : Try(List(ReconcileCron.Claimed), _)
		claimed = db.all!(Reconcile.claim_sql(), (now, Reconcile.max_rows))
		match claimed {
			Err(e) => Log.warn!("reconcile claim failed", { error: Str.inspect(e) })
			Ok(rows) => rows!(now, Sorted.sort_with(rows, by_repo))
		}
		Ok({})
	}

	## One row of the claim (`Reconcile.claim_sql`). `repo`, `repository_id` and `repository_owner_id` are 64-bit ids as text (R-IK2). An empty `etag` or `repo_etag` is NULL.
	## `name` is the lower-case name of the row.
	Claimed : {
		repo : Str,
		repository_id : Try(Str, [Missing]),
		etag : Str,
		fail_count : U32,
		app_installed : Bool,
		releases : Str,
		repo_etag : Str,
		name : Str,
		repository_owner_id : Try(Str, [Missing]),
		state : U64,
	}

	db = D1.binding("DB")

	## Q370: the rows in the order of `repo` as a signed 64-bit integer.
	by_repo : ReconcileCron.Claimed, ReconcileCron.Claimed -> [Before, Same, After]
	by_repo = |a, b| {
		x = I64.from_str(a.repo) ?? 0
		y = I64.from_str(b.repo) ?? 0
		if (x < y) Before else if (x > y) After else Same
	}

	## Each row, one at a time. After a row that saw the reserve (R-PU25, Q377), the rows that were not started move to the reset time, and the run stops.
	rows! : U64, List(ReconcileCron.Claimed) => {}
	rows! = |now, rows| {
		var $started = 0
		for c in rows {
			$started = $started + 1
			match row!(now, c) {
				Err(Go) => {}
				Ok(at) => {
					move!(at, rows.drop_first($started))
					break
				}
			}
		}
	}

	## R-PU25: one statement for all the rows that were not started. `fail_count` stays.
	move! : U64, List(ReconcileCron.Claimed) => {}
	move! = |at, rest| {
		ids = Str.join_with(rest.map(|c| "\"${c.repo}\""), ",")
		if !rest.is_empty() {
			stmt = Sql.stmt("UPDATE repo_checks SET next_check_at = ?1 WHERE repo IN (SELECT CAST(value AS INTEGER) FROM json_each(?2))", (at, "[${ids}]"))
			match db.batch!([stmt]) {
				Ok(_) => {}
				Err(e) => Log.warn!("reconcile rate reserve move failed", { error: Str.inspect(e) })
			}
		}
		Log.warn!("reconcile rate reserve", { reset_ms: at, moved: rest.len() })
	}

	## One row: the check, or the failure update and its log line (R-PU37 rows 2 to 4). The result is the reserve of the answers of the row.
	row! : U64, ReconcileCron.Claimed => Try(U64, [Go])
	row! = |now, c| {
		interval = Reads.interval_ms(c.app_installed)
		repository_id = match c.repository_id {
			Ok(text) => U64.from_str(text) ?? 0
			Err(Missing) => 0
		}
		match check!(now, interval, repository_id, c) {
			Ok(reserve) => reserve
			Err({ error, reserve }) => {
				n = if (c.fail_count == U32.highest) c.fail_count else c.fail_count + 1
				stmt = Sql.stmt("UPDATE repo_checks SET fail_count = ?2, next_check_at = ?3 WHERE repo = CAST(?1 AS INTEGER)", (c.repo, n, Reconcile.next_check(now, interval, n)))
				_ = db.batch!([stmt])
				Log.warn!("reconcile row failed", { job: "reconcile", repository_id, fail_count: n, error })
				reserve
			}
		}
	}

	Failure : { error : Str, reserve : Try(U64, [Go]) }

	## The reserve of one GitHub answer (R-PU25).
	reserve_of : Response -> Try(U64, [Go])
	reserve_of = |res| Reconcile.reserve({ remaining: header(res, "x-ratelimit-remaining"), limit: header(res, "x-ratelimit-limit"), reset: header(res, "x-ratelimit-reset") })

	header : Response, Str -> Try(Str, [None])
	header = |res, name| res.header(name).map_err(|_| None)

	## The later of 2 reserves (Q377: the row does all its work, then the run moves the rest).
	either : Try(U64, [Go]), Try(U64, [Go]) -> Try(U64, [Go])
	either = |a, b| match (a, b) {
		(Ok(x), Ok(y)) => Ok(if (x > y) x else y)
		(Ok(x), Err(Go)) => Ok(x)
		(Err(Go), other) => other
	}

	## The pass update (R-PU23, Q374, Q371): `checked_at`, the interval, `fail_count` 0, the list `etag` and the `repo_etag` of the visibility read. `Keep` does not change a column.
	pass : U64, U64, ReconcileCron.Claimed, ReconcileCron.Etags -> Sql.Stmt
	pass = |now, interval, c, etags| {
		next = Reconcile.next_check(now, interval, 0)
		value = |e| match e {
			Keep => Err(None)
			Set(v) => v
		}
		flag = |e| match e {
			Keep => 0.U8
			Set(_) => 1
		}
		sql = "UPDATE repo_checks SET checked_at = ?2, next_check_at = ?3, fail_count = 0, etag = CASE WHEN ?4 = 1 THEN ?5 ELSE etag END, repo_etag = CASE WHEN ?6 = 1 THEN ?7 ELSE repo_etag END WHERE repo = CAST(?1 AS INTEGER)"
		Sql.stmt(sql, (c.repo, now, next, flag(etags.etag), Sql.or_null(value(etags.etag)), flag(etags.repo_etag), Sql.or_null(value(etags.repo_etag))))
	}

	## The 2 etags of the pass: the list `etag` (R-PU23) and the `repo_etag` of the visibility read (Q371).
	Etags : { etag : [Keep, Set(Try(Str, [None]))], repo_etag : [Keep, Set(Try(Str, [None]))] }

	keep : ReconcileCron.Etags
	keep = { etag: Keep, repo_etag: Keep }

	## The writes of one change (as `IndexQueue.write_changes!`). Each write is guarded by the value that the claim saw (R-PU36: a webhook job can write the row during the run).
	## A clear has `withdrawn = ?2` (also `repo-missing`, R-PU24); a row that the claim did not give binds NULL, so it changes nothing.
	change_stmt : U64, List(Reconcile.Indexed), Webhook.Change -> Sql.Stmt
	change_stmt = |now, rows, change| match change.to {
		Ok(value) => Sql.stmt("UPDATE releases SET withdrawn = ?2, withdrawn_at = ?3 WHERE log_index = ?1 AND withdrawn IS NULL", (change.log_index, value, now))
		Err(Clear) => {
			seen = match rows.find_first(|r| r.log_index == change.log_index) {
				Ok(r) => r.withdrawn
				Err(NotFound) => Err(None)
			}
			Sql.stmt("UPDATE releases SET withdrawn = NULL, withdrawn_at = NULL WHERE log_index = ?1 AND withdrawn = ?2", (change.log_index, Sql.or_null(seen)))
		}
	}

	## The visibility read, then the list read (R-PU23, R-PU24, R-PU31). `Ok` is a pass, with the reserve of its answers.
	## Q371: the read sends `if-none-match` with the stored `repo_etag`. A 304 is public with the name of the row and the same ids: no identity write, `repo_etag` stays.
	check! : U64, U64, U64, ReconcileCron.Claimed => Try(Try(U64, [Go]), ReconcileCron.Failure)
	check! = |now, interval, repository_id, c| {
		if repository_id == 0 {
			return Err({ error: "the row has no repository id", reserve: Err(Go) })
		}
		ask = Request.get(Identity.repo_by_id_url(repository_id))
		request = if (c.repo_etag.is_empty()) ask else ask.with_header("if-none-match", c.repo_etag)
		res = GithubRead.send!(request).map_err(|e| { error: "the repository read failed: ${Str.inspect(e)}", reserve: Err(Go) })?
		first = reserve_of(res)
		at_first = |error| { error, reserve: first }
		status = res.status()
		if status == 304 {
			return list!(now, interval, repository_id, c, c.name, first, { stmts: [], repo_etag: Keep })
		}
		body = if (status == 200) res.text!().map_err(|_| at_first("the repository answer has no text"))? else ""
		outcome = Webhook.repository_outcome({ status, body }).map_err(|Upstream(text)| at_first(text))?
		match outcome {
			Withdraw => {
				stmts = IndexQueue.withdraw_stmts(repository_id, now).append(pass(now, interval, c, keep))
				_ = db.batch!(stmts).map_err(|e| at_first(Str.inspect(e)))?
				Ok(first)
			}
			Stale => {
				full_name = Identity.full_name_of(body).map_err(|_| at_first("the repository answer has no full name"))?
				repo = Ingest.parse_repo(body).map_err(|_| at_first("the repository answer is not a repository"))?
				seen = seen_of(now, interval, c, full_name, repo).map_err(at_first)?
				repo_etag = Reconcile.repo_etag_of({ public: repo.public, row_name: c.name, full_name, etag: header(res, "etag") })
				list!(now, interval, repository_id, c, full_name, first, { stmts: identity_stmts(seen), repo_etag: Set(repo_etag) })
			}
		}
	}

	## The identity part of the batch of a row (the statements before the release changes) and the `repo_etag` of the pass.
	Ident : { stmts : List(Sql.Stmt), repo_etag : [Keep, Set(Try(Str, [None]))] }

	## What the identity statements need: `u` the claimed row, `f` the row of the current name `F` (`name`, the `full_name` in lower case), the ids of the read by id,
	## the clock, and for a new row of `F` its `next_check_at` and `app_installed` (from the claimed row, Q380).
	Seen : { u : I64, f : I64, name : Str, repository_id : U64, owner_id : U64, now : U64, next : U64, app_installed : U8 }

	seen_of : U64, U64, ReconcileCron.Claimed, Str, Ingest.Repo -> Try(ReconcileCron.Seen, Str)
	seen_of = |now, interval, c, full_name, repo| {
		name = full_name.with_ascii_lowercased()
		parts = name.split_first("/").map_err(|_| "the full name of the repository answer has no owner")?
		u = I64.from_str(c.repo).map_err(|_| "the claimed row has a repo id that is not a number")?
		flag : U8
		flag = if (c.app_installed) 1 else 0
		Ok({ u, f: Reads.repo_id(parts.before, parts.after), name, repository_id: repo.id, owner_id: repo.owner_id, now, next: now + interval, app_installed: flag })
	}

	## R-TP9, R-TP10, R-TP11, R-TP18 rows 1, 3, 4 with U = F, R-TP19 "Order", Design Q378 to Q381. Each statement has the SQL guards of slice 113, so a statement that does not
	## apply (or a second run) writes nothing, and an event is written only when its row changes. In order:
	## 1. When `F` is another name: R-TP9 row 2 on the claimed row, and the `names` row of `F` when it has none.
	## 2. R-TP9 row 2 on the row of `F` (its own ids; a row of another `repository_id` gets nothing). The claimed row gets its transfer also when `F` has a row of another id (Q381).
	## 3. R-TP18 rows 1 and 3: when `F` has no row, or its row is `moved` with the same id, each other row of the id that is not `moved` gets `moved`, successor `F`, event `rename`.
	## 4. Row 1: the `repos` row of `F` (the ids of the read, the event `rename` only) and its `repo_checks` row.
	## 5. Row 3: the `moved` row of `F` gets `active`, no successor, event `rename`.
	## 6. R-TP11: a `missing` row of `F` gets `active`, event `found`.
	## A row of `F` with another `repository_id` gets no write, and the claimed row does not become `moved`.
	identity_stmts : ReconcileCron.Seen -> List(Sql.Stmt)
	identity_stmts = |s| {
		cols = IngestRoutes.event_cols
		seq = "(SELECT COALESCE(MAX(seq), 0) + 1 FROM repo_events e WHERE e.repo = r.repo)"
		transfer = |x| [
			Sql.stmt(
				"${cols} SELECT r.repo, ${seq}, 1, r.repository_id, r.repository_id, r.repository_owner_id, ?3, r.successor, NULL, ?4 FROM repos r WHERE r.repo = ?1 AND r.repository_id = ?2 AND r.repository_owner_id <> ?3",
				(x, s.repository_id, s.owner_id, s.now),
			),
			Sql.stmt(
				"UPDATE repos SET repository_owner_id = ?3 WHERE repo = ?1 AND repository_id = ?2 AND repository_owner_id <> ?3",
				(x, s.repository_id, s.owner_id),
			),
		]
		other = if (s.u == s.f) [] else transfer(s.u).append(Sql.stmt("INSERT INTO names (id, kind, value) SELECT ?1, 3, ?2 WHERE NOT EXISTS (SELECT 1 FROM names WHERE id = ?1)", (s.f, s.name)))
		mark = Sql.stmt(
			"UPDATE repos SET state = 2, successor = ?1, state_at = ?2 WHERE repository_id = ?3 AND repo <> ?1 AND state <> 2 AND (NOT EXISTS (SELECT 1 FROM repos WHERE repo = ?1) OR EXISTS (SELECT 1 FROM repos WHERE repo = ?1 AND state = 2 AND repository_id = ?3))",
			(s.f, s.now, s.repository_id),
		)
		marked = IngestRoutes.marked_events_stmt(s.f, s.repository_id, s.now, Err(None))
		insert = Sql.stmt(
			"INSERT INTO repos (repo, repository_id, repository_owner_id, state, successor, state_at, time) SELECT ?1, ?2, ?3, 0, NULL, ?4, ?4 WHERE NOT EXISTS (SELECT 1 FROM repos WHERE repo = ?1)",
			(s.f, s.repository_id, s.owner_id, s.now),
		)
		named = Sql.stmt(
			"${cols} SELECT ?1, (SELECT COALESCE(MAX(seq), 0) + 1 FROM repo_events WHERE repo = ?1), 2, NULL, ?2, NULL, ?3, NULL, NULL, ?4 WHERE changes() > 0",
			(s.f, s.repository_id, s.owner_id, s.now),
		)
		checks = Sql.stmt(
			"INSERT INTO repo_checks (repo, etag, checked_at, next_check_at, fail_count, app_installed, repo_etag) SELECT ?1, NULL, NULL, ?2, 0, ?3, NULL WHERE NOT EXISTS (SELECT 1 FROM repo_checks WHERE repo = ?1) AND EXISTS (SELECT 1 FROM repos WHERE repo = ?1 AND repository_id = ?4)",
			(s.f, s.next, s.app_installed, s.repository_id),
		)
		revive = Sql.stmt("UPDATE repos SET state = 0, successor = NULL, state_at = ?2 WHERE repo = ?1 AND state = 2 AND repository_id = ?3", (s.f, s.now, s.repository_id))
		revived = Sql.stmt(
			"${cols} SELECT r.repo, ${seq}, 2, r.repository_id, r.repository_id, r.repository_owner_id, r.repository_owner_id, NULL, NULL, ?2 FROM repos r WHERE r.repo = ?1 AND changes() > 0",
			(s.f, s.now),
		)
		found = Sql.stmt("UPDATE repos SET state = 0, state_at = ?2 WHERE repo = ?1 AND state = 1 AND repository_id = ?3", (s.f, s.now, s.repository_id))
		found_event = Sql.stmt(
			"${cols} SELECT r.repo, ${seq}, 5, r.repository_id, r.repository_id, r.repository_owner_id, r.repository_owner_id, r.successor, NULL, ?2 FROM repos r WHERE r.repo = ?1 AND changes() > 0",
			(s.f, s.now),
		)
		other.concat(transfer(s.f)).concat([mark, marked, insert, named, checks, revive, revived, found, found_event])
	}

	## The list read (R-PU23) and its pages (Q372), the send of the candidates first, then ONE batch: the identity, the changes, the pass with the etags (R-PU37 row 5).
	## Only page 1 sends `if-none-match`. More than one page: the pass stores `etag` NULL.
	list! : U64, U64, U64, ReconcileCron.Claimed, Str, Try(U64, [Go]), ReconcileCron.Ident => Try(Try(U64, [Go]), ReconcileCron.Failure)
	list! = |now, interval, repository_id, c, full_name, first, ident| {
		ask = Request.get(Reconcile.page_url(full_name, 1))
		request = if (c.etag.is_empty()) ask else ask.with_header("if-none-match", c.etag)
		page1 = page!(request, first)?
		var $reserve = page1.reserve
		stmts = match page1.outcome {
			NotModified => ident.stmts.append(pass(now, interval, c, { etag: Keep, repo_etag: ident.repo_etag }))
			Changed({ etag, list }) => {
				var $pages = [list]
				var $link = page1.link
				var $n = 1
				while Reconcile.has_next($link) {
					if $n >= Reconcile.max_pages {
						return Err({ error: "the release list has more than ${Reconcile.max_pages.to_str()} pages", reserve: $reserve })
					}
					$n = $n + 1
					next = page!(Request.get(Reconcile.page_url(full_name, $n)), $reserve)?
					$reserve = next.reserve
					match next.outcome {
						NotModified => return Err({ error: "the release list page ${$n.to_str()} answered status 304", reserve: $reserve })
						Changed(more) => {
							$pages = $pages.append(more.list)
							$link = next.link
						}
					}
				}
				stored = if ($n > 1) Err(None) else etag
				rows = Reconcile.indexed_of(c.releases).map_err(|_| { error: "the indexed releases of the claim are not valid", reserve: $reserve })?
				work = Reconcile.list_work({ full_name, rows, list: Reconcile.merge_pages($pages) })
				if !work.candidates.is_empty() {
					sent = IndexQueue.index.send_batch!(work.candidates.map(|id| Reconcile.message_of(repository_id, id)))
					match sent {
						Ok(_) => {}
						Err(e) => return Err({ error: "the send of the candidates failed: ${Str.inspect(e)}", reserve: $reserve })
					}
				}
				ident.stmts.concat(work.changes.map(|change| change_stmt(now, rows, change))).append(pass(now, interval, c, { etag: Set(stored), repo_etag: ident.repo_etag }))
			}
		}
		match db.batch!(stmts) {
			Ok(_) => Ok($reserve)
			Err(e) => Err({ error: Str.inspect(e), reserve: $reserve })
		}
	}

	## One page of the list: the read, its reserve (with the reserve before it), its outcome and its `Link` header.
	page! : Request, Try(U64, [Go]) => Try({ outcome : Reconcile.ListOutcome, link : Try(Str, [None]), reserve : Try(U64, [Go]) }, ReconcileCron.Failure)
	page! = |request, before| {
		res = GithubRead.send!(request).map_err(|e| { error: "the release list read failed: ${Str.inspect(e)}", reserve: before })?
		reserve = either(before, reserve_of(res))
		fail = |error| { error, reserve }
		status = res.status()
		body = if (status == 200) res.text!().map_err(|_| fail("the release list answer has no text"))? else ""
		link = header(res, "link")
		outcome = Reconcile.list_outcome({ status, etag: header(res, "etag"), link, body }).map_err(|Failed(text)| fail(text))?
		Ok({ outcome, link, reserve })
	}
}
