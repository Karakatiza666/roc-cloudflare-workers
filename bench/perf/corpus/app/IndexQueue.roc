## The index queue (Registry R-PU11, R-PU13, R-PU35, R-PU45, R-WH14 `INDEX` and `INDEX_DLQ`; slice 118). The decisions are in `lib/Webhook.roc` (pure, W0). The tests are W2: `worker/tests/cases/webhook/`.
## `main.roc` declares `IndexQueue.index` in `Worker.new({ bindings })` and its `queue!` calls `IndexQueue.consume!`. Every body here is a stub until the code agent writes it (TW18).
import pf.Queue
import pf.Cbor
import pf.D1
import pf.Http
import pf.Log
import pf.Request
import pf.Sql
import pf.Time
import lib.Webhook
import lib.Ingest
import lib.Identity
import lib.Problem
import lib.Reads
import GithubRead
import IngestRoutes

IndexQueue :: [].{

	## The producer binding `INDEX` (R-WH14): the queue `Webhook.queue_name`, messages of the type `Webhook.Message` (content type `json`).
	index : Queue(Webhook.Message)
	index = Queue.json("INDEX")

	## The consumer of the Worker: one `queue!` for all the queues of the Worker. `Queue.Batch.queue` is the name of the queue.
	## - `Webhook.dlq_name`: for each message write ONE log line and ack it: `Log.error!("index job dead", fields)`. `fields` are `event`, `action`, `repository_id`, `release_id` of the message (no name, R-PU32).
	##   A body that is not a `Webhook.Message`: the line `Log.error!("index job dead", { readable: Bool.False })`, and ack it.
	## - `Webhook.queue_name`: one message at a time, in the order of the batch. Do not use `Queue.each!`: it acks after an `Ok` and retries with no delay after an `Err`. Read the body with
	##   `Cbor.parse(Queue.Message.body(m))` as a `Webhook.Message`, then `Webhook.job_of`, then run the job (below). The result of a job:
	##   `Ok` is `m.ack!()`. `Err(why)` is a failure: `Webhook.retry_delay_ms(m.attempts())`: `Ok(ms)` is `m.retry_with!({ delay_ms: ms })`, `Err(GiveUp)` is `m.retry!()` (the platform moves the message to the dead letter queue, R-PU45; only if the first-deploy edge check of R-PU45 fails, the consumer sends the message to `INDEX_DLQ` itself and acks it: a later change, with its own tests). A failure also writes one
	##   `Log.warn!("index job failed", { event, action, repository_id, attempts, error })` (no name). A body that is not a message, or `Err(Unknown)` from `job_of`, is a failure.
	##   `Release(..)`: slice 118b. Until then it is a failure with the error `not done`.
	## - `Privatized(id)` (R-PU33, R-PU31, R-PU12): `GET https://api.github.com/repositories/<id>` (the headers of the other GitHub reads), then `Webhook.repository_outcome` with the status and the body text. `Err(Upstream)`, and
	##   no answer, is a failure. `Stale` writes nothing. `Withdraw` is one `batch!` on the primary (a repository with no `repos` row writes nothing, R-PU32): for each `repos` row with `repository_id` = id and
	##   `state` not `moved` that `Identity.went_missing` changes: `UPDATE repos` (guarded by the old state) and one `repo_events` row `Missing` (`WHERE changes() > 0`); and for the releases of EVERY row with that
	##   `repository_id` (also `moved`): `UPDATE releases SET withdrawn = 'repo-missing', withdrawn_at = <now> WHERE repo IN (..) AND withdrawn IS NULL`. The clock is `Time.now_ms!()` once.
	## - `Publicized(id)` (R-PU33, Design Q324): no GitHub read. `UPDATE repo_checks SET next_check_at = <now> WHERE repo IN (the `repos` rows with that `repository_id` and `state` not `moved`)`. The state of `repos` and `withdrawn` do not change
	##   (the next reconcile does that, R-PU24, slice 119). A repository with no row: nothing is written.
	## - `AppInstalled({ repository_ids, installed })` (R-PU26, Design Q322, Q324): `UPDATE repo_checks SET app_installed = <1 or 0> WHERE repo IN (EVERY `repos` row, also `moved`, with `repository_id` in the list)`. An id with no row writes nothing:
	##   no row is added (R-PU32). No GitHub read. No change of `next_check_at`.
	## No job counts as a D1 call of a request (R-AP41): the consumer has no limit on the count.
	consume! : Queue.Batch => Try({}, [Fault(Str)])
	consume! = |batch| {
		queue = batch.queue()
		if queue == Webhook.dlq_name {
			for m in batch.messages() {
				dead!(m)
			}
			Ok({})
		} else if queue == Webhook.queue_name {
			for m in batch.messages() {
				work!(m)
			}
			Ok({})
		} else {
			Err(Fault("the Worker has no consumer for the queue ${queue}"))
		}
	}

	## The dead letter queue: one log line for each message, then ack (R-PU35, R-PU32: the ids only).
	dead! : Queue.Message => {}
	dead! = |m| {
		read : Try(Webhook.Message, _)
		read = Cbor.parse(m.body())
		match read {
			Ok(x) => Log.error!("index job dead", { event: x.event, action: x.action, repository_id: x.repository_id, release_id: x.release_id })
			Err(_) => Log.error!("index job dead", { readable: Bool.False })
		}
		m.ack!()
	}

	## One job: ack after `Ok`. After `Err`: a log line, then the retry with the delay of the attempt, or with no delay at the last attempt (R-PU13, R-PU35).
	work! : Queue.Message => {}
	work! = |m| match run!(m) {
		Ok({}) => m.ack!()
		Err(why) => {
			attempts = m.attempts()
			Log.warn!("index job failed", { attempts, error: why })
			match Webhook.retry_delay_ms(attempts) {
				Ok(ms) => m.retry_with!({ delay_ms: ms })
				Err(GiveUp) => m.retry!()
			}
		}
	}

	run! : Queue.Message => Try({}, Str)
	run! = |m| {
		read : Try(Webhook.Message, _)
		read = Cbor.parse(m.body())
		message = read.map_err(|_| "the body is not an index message")?
		job = Webhook.job_of(message).map_err(|_| "the message is not a job of this Worker")?
		job!(job, m.attempts())
	}

	job! : Webhook.Job, U32 => Try({}, Str)
	job! = |job, attempts| match job {
		Release(r) => release!(r, attempts, 1)
		Privatized(id) => privatized!(id)
		Publicized(id) => publicized!(id)
		AppInstalled({ repository_ids, installed }) => app_installed!(repository_ids, installed)
		Poll(p) => poll!(p, attempts)
	}

	## Slice 119b (R-PU21, R-PU15, R-PU23): the job of a candidate that the reconcile found. It is the job `Release` (all 6 steps above) with the action `published`, `installation_id` 0, and the
	## provenance `poll` (via 2) in place of `webhook` (via 1): the label pre-read (`IngestRoutes.label_sql_of(2)`), `AddProvenance` (the row `via` 2 only) and the flow of `IngestRoutes.index!` (`via: 2`).
	## Thread the `via` through `release!`, `release_work!` and `index_label!`; a webhook job keeps via 1. A message that comes 2 times is not a fault (R-PU14): the second time writes nothing.
	poll! : { repository_id : U64, release_id : U64 }, U32 => Try({}, Str)
	poll! = |job, attempts| release!({ action: "published", repository_id: job.repository_id, release_id: job.release_id, installation_id: 0 }, attempts, 2)

	## Slice 118b: the job `Release`, in the order of the comment of `Webhook` (section 118b). `attempts` is the attempt of the message (the first delivery is 1): a release with no package asset at the fifth attempt ends with `Ok` and the
	## info line `Log.info!("index job no asset", { repository_id, release_id })` (Design Q334). The action `deleted` does no release read and no `releases` write (Q336). Every job whose repository read shows public sets `app_installed` when `installation_id` >= 1 (Q362). A 4xx refusal of the shared flow is acked with `Log.warn!("index job refused", { repository_id, release_id, type })` (Q361). `Ok({})` is an ack. `Err(text)` is a failure: the consumer retries (`work!`).
	## `via` is the provenance code of a new release: 1 (`webhook`) for a webhook job, 2 (`poll`) for the job `Poll`.
	release! : { action : Str, repository_id : U64, release_id : U64, installation_id : U64 }, U32, U8 => Try({}, Str)
	release! = |job, attempts, via| {
		answer = read_repository!(job.repository_id)?
		match answer.outcome {
			Withdraw => withdraw!(job.repository_id)
			Stale => {
				found = public_repo(answer.body)?
				done = release_work!(job, attempts, via, found)
				match done {
					Err(text) => {
						# The job is retried: the flag is set again then, a fault of this write is not the cause.
						_ = mark_installed!(job, Nothing)
						Err(text)
					}
					Ok(outcome) => mark_installed!(job, outcome)
				}
			}
		}
	}

	## What a job leaves for the last step: `Added` when the index added the `repos` row of the name (its check interval is then 24 h if the app is installed, Q335).
	Outcome : [Added({ repo : I64, now : U64 }), Nothing]

	ReleaseJob : { action : Str, repository_id : U64, release_id : U64, installation_id : U64 }

	## Step 1: `GET /repositories/<id>`, then `Webhook.repository_outcome`. The body is the text of a 200 answer.
	read_repository! : U64 => Try({ outcome : [Withdraw, Stale], body : Str }, Str)
	read_repository! = |id| {
		res = GithubRead.send!(Request.get("https://api.github.com/repositories/${id.to_str()}")).map_err(|e| "the repository read failed: ${Str.inspect(e)}")?
		status = res.status()
		body = if (status == 200) res.text!().map_err(|_| "the repository answer has no text")? else ""
		match Webhook.repository_outcome({ status, body }) {
			Ok(outcome) => Ok({ outcome, body })
			Err(Upstream(text)) => Err(text)
		}
	}

	public_repo : Str -> Try({ repo : Ingest.Repo, full_name : Str }, Str)
	public_repo = |body| {
		repo = Ingest.parse_repo(body).map_err(|_| "the repository answer is not a repository")?
		full_name = Identity.full_name_of(body).map_err(|_| "the repository answer has no full name")?
		Ok({ repo, full_name })
	}

	## Steps 2 to 5 for a repository that is public.
	release_work! : IndexQueue.ReleaseJob, U32, U8, { repo : Ingest.Repo, full_name : Str } => Try(IndexQueue.Outcome, Str)
	release_work! = |job, attempts, via, found| {
		if job.action == "deleted" {
			publicized!(job.repository_id)?
			return Ok(Nothing)
		}
		res = GithubRead.send!(Request.get("https://api.github.com/repos/${found.full_name}/releases/${job.release_id.to_str()}")).map_err(|e| "the release read failed: ${Str.inspect(e)}")?
		if res.status() == 404 {
			return Ok(Nothing)
		}
		if res.status() != 200 {
			return Err("GitHub answered the release read with status ${res.status().to_str()}")
		}
		text = res.text!().map_err(|_| "the release answer has no text")?
		read = Webhook.parse_release(text).map_err(|_| "the release answer is not a release")?
		step = Webhook.release_step({ action: job.action, full_name: found.full_name, read })
		session = db.with_session!(Primary).map_err(fault)?
		write_changes!(session, job.repository_id, read, step)?
		match step {
			Index(url) => index_label!(session, job, via, found, url)
			NoAsset => match Webhook.after_no_asset(attempts) {
				Retry(_) => Err("the release has no package asset yet")
				Done => {
					Log.info!("index job no asset", { repository_id: job.repository_id, release_id: job.release_id })
					Ok(Nothing)
				}
			}
			_ => Ok(Nothing)
		}
	}

	## Step 3: R-PU17 and R-PU20 on the rows of the release. The writes are one batch, before the rest of the job (Q363).
	write_changes! : D1.Session, U64, Webhook.ReleaseRead, Webhook.Step => Try({}, Str)
	write_changes! = |session, repository_id, read, step| {
		state = match step {
			Withdraw(value) => Withdrawn(value)
			Index(_) => Final({ assets: read.release.assets, candidate: Bool.True })
			NoAsset | TooMany => Final({ assets: read.release.assets, candidate: Bool.False })
			Skip => return Ok({})
		}
		found : Try(List({ log_index : U64, hash : Str, withdrawn : Try(Str, [Missing]) }), _)
		found = session.all!(
			"SELECT r.log_index AS log_index, l.hash AS hash, r.withdrawn AS withdrawn FROM releases r JOIN log l ON l.idx = r.log_index WHERE r.tag = ?2 AND r.repo IN (SELECT repo FROM repos WHERE repository_id = ?1) ORDER BY r.log_index",
			(repository_id, read.tag),
		)
		rows = found.map_err(fault)?.map(
			|r| {
				withdrawn = match r.withdrawn {
					Ok(value) => Ok(value)
					Err(Missing) => Err(None)
				}
				{ log_index: r.log_index, hash: r.hash, withdrawn }
			},
		)
		changes = Webhook.row_changes({ state, rows })
		if changes.is_empty() {
			return Ok({})
		}
		now = Time.now_ms!()
		stmts = changes.map(
			|c| match c.to {
				Ok(value) => Sql.stmt("UPDATE releases SET withdrawn = ?2, withdrawn_at = ?3 WHERE log_index = ?1 AND withdrawn IS NULL", (c.log_index, value, now))
				Err(Clear) => Sql.stmt("UPDATE releases SET withdrawn = NULL, withdrawn_at = NULL WHERE log_index = ?1", [c.log_index])
			},
		)
		session.batch!(stmts).map_ok(|_| {}).map_err(fault)
	}

	## Step 4: the label of the asset URL, and the shared ingest flow with `via` 1 or 2 (R-PU14, R-PU15, R-PU19, R-PU21, Q333, Q361).
	index_label! : D1.Session, IndexQueue.ReleaseJob, U8, { repo : Ingest.Repo, full_name : Str }, Str => Try(IndexQueue.Outcome, Str)
	index_label! = |session, job, via, found, url| {
		target = match Ingest.parse_url(url) {
			Ok(t) => t
			Err(problem) => return refused!(job, problem)
		}
		repo_id = Reads.repo_id(target.owner, target.repo)
		label_stmt = Sql.stmt(IngestRoutes.label_sql_of(via), IngestRoutes.label_params(target))
		first = session.batch!([label_stmt, Sql.stmt(IngestRoutes.repo_sql, [repo_id])]).map_err(fault)?
		label = first.first().map_err(|_| "the pre-read gave no result")?
		rows = IngestRoutes.label_rows(label.all()).map_err(failed)?
		old = IngestRoutes.old_row(first, 1, repo_id).map_err(failed)?
		action = Ingest.after_read(target, rows).map_err(|BadRow(text)| text)?
		match action {
			Conflict(_) => {
				Log.warn!("index label conflict", { repository_id: job.repository_id, release_id: job.release_id, group: target.form, version: target.version.to_str() })
				Ok(Nothing)
			}
			Answer(_) => Ok(Nothing)
			AddProvenance(log_index) => {
				stmt = Sql.stmt("INSERT INTO provenance (release, via, claims, time) SELECT ?1, ?3, NULL, ?2 WHERE NOT EXISTS (SELECT 1 FROM provenance WHERE release = ?1 AND via = ?3)", (log_index, Time.now_ms!(), via))
				_ = session.batch!([stmt]).map_err(fault)?
				Ok(Nothing)
			}
			Index => {
				now = Time.now_ms!()
				identity = match IngestRoutes.identity!(target, repo_id, found, old, now, Err(None)).map_err(failed)? {
					Stop(_) => {
						Log.warn!("index job repository changed", { repository_id: job.repository_id, release_id: job.release_id })
						return Ok(Nothing)
					}
					Go(done) => done.stmts
				}
				flow = { repo: found.repo, identity, now, via, claims: Err(None), extra: [], candidate: Ingest.candidate, no_release: Ingest.no_release }
				match IngestRoutes.index!(session, target, flow) {
					Ok(_) => match old {
						Err(None) => Ok(Added({ repo: repo_id, now }))
						Ok(_) => Ok(Nothing)
					}
					Err(Refuse(problem)) => if (problem.http_status() < 500) refused!(job, problem) else Err(problem.detail_of())
					Err(Fault(text)) => Err(text)
				}
			}
		}
	}

	## A refusal with a 4xx type is final: one warn line with the ids and the type, then an ack (Q361).
	refused! : IndexQueue.ReleaseJob, Problem => Try(IndexQueue.Outcome, Str)
	refused! = |job, problem| {
		Log.warn!("index job refused", { repository_id: job.repository_id, release_id: job.release_id, type: problem.type_of() })
		Ok(Nothing)
	}

	failed : IngestRoutes.Error -> Str
	failed = |e| match e {
		Refuse(problem) => problem.detail_of()
		Fault(text) => text
	}

	## Step 6 and Q362: a job with an installation sets `app_installed` on every row of the repository. A row that the job added has the interval of 24 h (Q335).
	mark_installed! : IndexQueue.ReleaseJob, IndexQueue.Outcome => Try({}, Str)
	mark_installed! = |job, outcome| {
		if job.installation_id < 1 {
			return Ok({})
		}
		flag = Sql.stmt("UPDATE repo_checks SET app_installed = 1 WHERE repo IN (SELECT repo FROM repos WHERE repository_id = ?1)", [job.repository_id])
		stmts = match outcome {
			Added({ repo, now }) => [flag, Sql.stmt("UPDATE repo_checks SET next_check_at = ?2 WHERE repo = ?1", (repo, now + Reads.interval_ms(Bool.True)))]
			Nothing => [flag]
		}
		db.batch!(stmts).map_ok(|_| {}).map_err(fault)
	}

	db = D1.binding("DB")

	fault = |e| Str.inspect(e)

	privatized! : U64 => Try({}, Str)
	privatized! = |id| {
		res = GithubRead.send!(Request.get("https://api.github.com/repositories/${id.to_str()}")).map_err(|e| "the repository read failed: ${Str.inspect(e)}")?
		status = res.status()
		body = if (status == 200) res.text!().map_err(|_| "the repository answer has no text")? else ""
		outcome = match Webhook.repository_outcome({ status, body }) {
			Ok(o) => o
			Err(Upstream(text)) => return Err(text)
		}
		match outcome {
			Stale => Ok({})
			Withdraw => withdraw!(id)
		}
	}

	## R-PU33, R-PU24, R-TP11, R-TP19: the row of the current name becomes `missing` with its event; the releases of every row of the repository get `repo-missing`. A repository with no row writes nothing.
	withdraw! : U64 => Try({}, Str)
	withdraw! = |id| {
		now = Time.now_ms!()
		session = db.with_session!(Primary).map_err(fault)?
		session.batch!(withdraw_stmts(id, now)).map_ok(|_| {}).map_err(fault)
	}

	## The 3 statements of `withdraw!`. The reconcile puts them in the batch of its row (R-PU24).
	## Slice 119c (Design Q376, R-PU24, R-PU33): a 4th statement sets `etag` and `repo_etag` to NULL on EVERY `repo_checks` row of the repository id (also a `moved` row), so the first public check reads a 200 list
	## and can clear `repo-missing`. It is in the same batch, for the reconcile and for the job `privatized`. A repository with no row writes nothing.
	withdraw_stmts : U64, U64 -> List(Sql.Stmt)
	withdraw_stmts = |id, now| {
		event = Sql.stmt(
			"INSERT INTO repo_events (repo, seq, action, repository_id_before, repository_id_after, owner_id_before, owner_id_after, successor, claims, time) SELECT r.repo, (SELECT COALESCE(MAX(seq), 0) + 1 FROM repo_events e WHERE e.repo = r.repo), 4, r.repository_id, r.repository_id, r.repository_owner_id, r.repository_owner_id, r.successor, NULL, ?2 FROM repos r WHERE r.repository_id = ?1 AND r.state = 0",
			(id, now),
		)
		state = Sql.stmt("UPDATE repos SET state = 1, state_at = ?2 WHERE repository_id = ?1 AND state = 0", (id, now))
		releases = Sql.stmt(
			"UPDATE releases SET withdrawn = 'repo-missing', withdrawn_at = ?2 WHERE withdrawn IS NULL AND repo IN (SELECT repo FROM repos WHERE repository_id = ?1)",
			(id, now),
		)
		etags = Sql.stmt("UPDATE repo_checks SET etag = NULL, repo_etag = NULL WHERE repo IN (SELECT repo FROM repos WHERE repository_id = ?1)", [id])
		[event, state, releases, etags]
	}

	## R-PU33, Q324: the rows that are not `moved` are checked now. The state and `withdrawn` stay.
	publicized! : U64 => Try({}, Str)
	publicized! = |id| {
		now = Time.now_ms!()
		stmt = Sql.stmt("UPDATE repo_checks SET next_check_at = ?2 WHERE repo IN (SELECT repo FROM repos WHERE repository_id = ?1 AND state <> 2)", (id, now))
		db.batch!([stmt]).map_ok(|_| {}).map_err(fault)
	}

	## R-PU26, Q322, Q324: every row of each repository, also `moved`. No row is added.
	app_installed! : List(U64), Bool => Try({}, Str)
	app_installed! = |ids, installed| {
		if ids.is_empty() {
			return Ok({})
		}
		flag : U8
		flag = if (installed) 1 else 0
		stmts = ids.map(|id| Sql.stmt("UPDATE repo_checks SET app_installed = ?2 WHERE repo IN (SELECT repo FROM repos WHERE repository_id = ?1)", (id, flag)))
		db.batch!(stmts).map_ok(|_| {}).map_err(fault)
	}
}
