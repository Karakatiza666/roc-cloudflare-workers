## The handler of `POST /v1/compat`, the user hint path (Registry R-AP10, R-AP25, R-AP41, R-CT1 to R-CT4, R-CT11 to R-CT14; slice 116). The decisions are in `lib/Hints.roc` and `lib/Client.roc` (pure, W0).
## The tests are W2: `worker/tests/cases/hints/`. `CompatRoutes.post!` calls this module for the kind `Hint` of `Compat.request_kind` (a request with no `Authorization` and with `Talon-Contributor`).
## The flow (the slice file `docs/slices/116a-user-hints.md` section 3.3, and 116b for the step 3):
## 1. `bytes` is the body read of `CompatRoutes.post!` (`Err(rejected)` is a body above 256 KB or a read fault, as for the bot path). The id: `Hints.machine_id(header)`. `Err(problem)`: the 400 `Refuse(problem)`.
##    A body that is too large: its 413 comes first, before the id check (R-AP48 row 4 before row 6; the bot path has the 413 first too, Design Q144).
## 2. `Hints.parse(bytes)`. `Bad(problem)`: `Err(Refuse(problem))`. `TooLarge(problem, extra)`: `Ok` of the 413 answer, as `CompatRoutes.post!`. No D1 call before this step.
## 3. (Slice 116b) The rate limit: the binding `RL_HINTS`, `limit!` with `Client.rate_key(req.header("cf-connecting-ip"))`. `Err(RateLimited)`: the 429 `Client.rate_problem()` with the header
##    `Retry-After: <Client.limit_retry_after>`. No D1 call. The binding fails (`Infra`): `Err(Fault(..))`. Slice 116a has no step 3.
## 4. D1 call 1: the read batch of the same 3 statements as `CompatRoutes.plan!` (3 statements on the primary, for `Hints.read_params`), then `Hints.check`. Copy the 3 statements: this module must not import `CompatRoutes` (it imports this module). `Err(problem)`: the 400. A body with no row skips this call and the next two.
## 5. The tag list: `Hints.tags_url` through a `Memo` of 1 h (`Memo.new("talon-tags", { max_age_ms: 3_600_000 })`), `Hints.tag_names` of the body; `Hints.talon_key({ version, tags })`. A GET that fails
##    (a status other than 200, a network fault, a body that `tag_names` refuses) keeps nothing in the `Memo` and gives the tags `[]`, so the key is 0 (R-CT12, Design Q178). No GitHub read for a request that ended in steps 1 to 4.
## 6. D1 call 2: one `batch!` on the primary of 3 statements, in this order: `Hints.first_sql()`, `Hints.skipped_sql()`, `Hints.insert_sql()`, with `Time.now_ms!()` once, `Hints.rows_json(sent)`,
##    the machine id `Hints.contributor_id(WebCrypto.hmac_sha256(secret CONTRIBUTOR_KEY bytes, Hints.hmac_message(machine)))` and the key of step 5. `first` is the column of the one row of statement 1. `skipped` are the rows of statement 2.
##    `written` is the count of rows that statement 3 returns (`RETURNING`), not `changes`. A body with rows that `check` all gives the same batch: no special case.
##    On `Err(Constraint(c))`: `Hints.failure_of(c)`. `Quota`: the 429 `Hints.quota_problem()` with `Retry-After: <Hints.retry_after(now)>`. `Fault(text)`: `Err(Fault(text))`. `Err(Infra(e))`: `Err(Fault(..))`.
## 7. 201 or 200 by `Compat.written_status`, `content-type: application/json`, `cache-control: no-store`, the body `Hints.answer_body(..)`.
## A missing secret `CONTRIBUTOR_KEY` is `Err(Fault(..))` (500), found before D1 call 2 (and after step 4: a request that fails earlier needs no secret).
import pf.Request
import pf.Response
import pf.D1
import pf.Sql
import pf.Time
import pf.Memo
import pf.Env
import pf.WebCrypto
import pf.RateLimit
import lib.Client
import lib.Compat
import lib.Hints
import lib.Problem
import ReadRoutes
import GithubRead

HintRoutes :: [].{

	db = D1.binding("DB")

	## The tag names of `roc-talon/talon`, kept for 1 h (R-CT12). The loader keeps nothing when it fails.
	tags : Memo(List(Str))
	tags = Memo.new("talon-tags", { max_age_ms: 3_600_000 })

	## R-CT11, R-MX6 (slice 116b): 30 user hint requests a minute for each rate key (`wrangler.toml` `[[ratelimits]]` `RL_HINTS`).
	limiter = RateLimit.binding("RL_HINTS")

	## The 429 of the limit (R-AP25): `Retry-After` is the period of the binding.
	limited_response : () -> Response
	limited_response = || {
		problem = Client.rate_problem()
		Response.from_bytes(problem.http_status(), "application/problem+json", problem.to_json().to_utf8()).with_header("retry-after", Client.limit_retry_after.to_str())
	}

	post! : Request, Try(List(U8), Compat.Reject) => Try(Response, ReadRoutes.Error)
	post! = |req, found| {
		bytes = match found {
			Ok(read) => read
			Err(rejected) => return rejected_answer(rejected)
		}
		machine = Hints.machine_id(req.header("talon-contributor") ?? "").map_err(|problem| Refuse(problem))?
		post = match Hints.parse(bytes) {
			Ok(parsed) => parsed
			Err(rejected) => return rejected_answer(rejected)
		}
		match limiter.limit!(Client.rate_key(req.header("cf-connecting-ip"))) {
			Ok({}) => {}
			Err(RateLimited) => return Ok(limited_response())
			Err(Infra(e)) => return Err(Fault(Str.inspect(e)))
		}
		if post.rows.is_empty() {
			return Ok(answer(0, 0, []))
		}
		sent = read!(post)?
		secret = Env.secret!("CONTRIBUTOR_KEY") ? |e| Fault(Str.inspect(e))
		key = Hints.talon_key({ version: post.talon_version, tags: tag_list!() })
		id = Hints.contributor_id(WebCrypto.hmac_sha256(secret.reveal().to_utf8(), Hints.hmac_message(machine)))
		write!(sent, id, key)
	}

	## A refused body or a body that was too large: the 400 or the 413.
	rejected_answer : Compat.Reject -> Try(Response, ReadRoutes.Error)
	rejected_answer = |rejected| match rejected {
		Bad(problem) => Err(Refuse(problem))
		TooLarge(problem, extra) => Ok(Response.from_bytes(413, "application/problem+json", Problem.to_json_with(problem, extra).to_utf8()))
	}

	## D1 call 1: the facts of the artifacts and targets, then `Hints.check` (the 400 of a target).
	read! : Hints.Post => Try(List(Hints.Sent), ReadRoutes.Error)
	read! = |post| {
		params = Hints.read_params(post)
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
			_ => Err(Fault("hints: the read batch gave ${results.len().to_str()} results, not 3"))
		}?
		Hints.check(post, facts).map_err(|problem| Refuse(problem))
	}

	## The tag names (R-CT12). A read that fails gives `[]`, and the `Memo` keeps nothing (Design Q178).
	tag_list! : () => List(Str)
	tag_list! = || tags.get!(load_tags!) ?? []

	load_tags! : () => Try(List(Str), [NoTags])
	load_tags! = || {
		res = GithubRead.send!(Request.get(Hints.tags_url)) ? |_| NoTags
		if res.status() != 200 {
			return Err(NoTags)
		}
		text = res.text!() ? |_| NoTags
		Hints.tag_names(text).map_err(|_| NoTags)
	}

	## D1 call 2: `first`, `skipped` and the insert in one batch on the primary. `written` is the count of the returned rows.
	write! : List(Hints.Sent), I64, I64 => Try(Response, ReadRoutes.Error)
	write! = |sent, id, key| {
		now = Time.now_ms!()
		json = Hints.rows_json(sent)
		stmts = [
			Sql.stmt(Hints.first_sql(), (json, now)),
			Sql.stmt(Hints.skipped_sql(), (json, now)),
			Sql.stmt(Hints.insert_sql(), (json, now, id.to_str(), key.to_str())),
		]
		results = match db.batch!(stmts) {
			Ok(found) => found
			Err(Constraint(c)) => return quota!(c, now)
			Err(Infra(e)) => return Err(Fault(Str.inspect(e)))
		}
		match results {
			[first_result, skipped_result, inserted_result] => {
				firsts : List({ first : U64 })
				firsts = all(first_result)?
				skipped : List(Hints.Skipped)
				skipped = all(skipped_result)?
				inserted : List({ artifact : Str })
				inserted = all(inserted_result)?
				first = match firsts {
					[one] => one.first
					_ => return Err(Fault("hints: the first statement gave ${firsts.len().to_str()} rows, not 1"))
				}
				Ok(answer(inserted.len(), first, skipped))
			}
			_ => Err(Fault("hints: the write batch gave ${results.len().to_str()} results, not 3"))
		}
	}

	## A failed write batch: the daily limit is the 429 with `Retry-After`, everything else is a fault.
	quota! : Compat.Constraint, U64 => Try(Response, ReadRoutes.Error)
	quota! = |c, now| match Hints.failure_of(c) {
		Quota => Ok(Response.from_bytes(429, "application/problem+json", Hints.quota_problem().to_json().to_utf8()).with_header("retry-after", Hints.retry_after(now).to_str()))
		Fault(text) => Err(Fault(text))
	}

	answer : U64, U64, List(Hints.Skipped) -> Response
	answer = |written, first, skipped| Response.from_bytes(Compat.written_status(written), "application/json", Hints.answer_body({ written, first, skipped }).to_utf8()).with_header("cache-control", "no-store")

	all = |result| result.all().map_err(|e| Fault(Str.inspect(e)))
}
