## The handlers of the four account routes (Registry R-AP35 to R-AP38, R-AP41, R-CT7 to R-CT11; slice 117). The decisions are in `lib/Login.roc` (pure, W0).
## The tests are W2: `worker/tests/cases/account/`. The slice file `docs/slices/117-login.md` section 3.3 has the flow of each route. Every body here is a stub.
## The common steps:
## - The proof (Q300): `Oidc.bearer(req.header("authorization"))` (`NoToken` is `Login.missing_token`, `Refuse(problem)` is the 401), the secret `TOKEN_KEY` through `Login.signing_key`
##   (`Err(BadKey)` or a missing secret is `Err(Fault(..))`), `Login.decode(text, key.kid)`, `WebCrypto.verify!({ alg: Ed25519, key: Jwk(key.public_json), signature, data: signing_input })`
##   (`BadSignature` is `Login.bad_signature`; a `CryptoErr` is also 401), then `Login.check` with the setting `AUDIENCE` and `Time.now_ms!()`. No D1 call before this ends.
## - The rate limit (Q308): `limiter.limit!(Client.rate_key(req.header("cf-connecting-ip")))`. `Err(RateLimited)` is the 429 `Login.rate_problem` with `Retry-After: 60`. `Err(Infra(..))` is a `Fault`.
## - The answers: `content-type: application/json` and `cache-control: no-store` for a body, 204 (`Response.from_status`) with `cache-control: no-store` for none. A `Constraint` error of D1 is a `Fault`.
import pf.Request
import pf.Response
import pf.D1
import pf.Sql
import pf.Http
import pf.Env
import pf.Time
import pf.WebCrypto
import pf.RateLimit
import records.Account
import lib.Client
import lib.Compat
import lib.Hints
import lib.Login
import lib.Oidc
import lib.Problem
import ReadRoutes

LoginRoutes :: [].{

	## R-CT11, R-WH14 (slice 117): 10 requests a minute for each rate key, shared by `POST /v1/tokens` and `DELETE /v1/contributors/me` (`wrangler.toml` `[[ratelimits]]` `RL_LOGIN`).
	limiter = RateLimit.binding("RL_LOGIN")

	db = D1.binding("DB")

	## What a proof gives: the account, `iat` of the token, and the time of the request (`Time.now_ms!`, read once).
	Proof : { who : Login.Verified, now : U64 }

	## `POST /v1/tokens` (R-AP37, R-CT8). The flow, the first check that fails gives the answer:
	## 1. The body: `req.bytes_with!({ max_bytes: Compat.body_limit })`. `Err(TooLarge)` is the 413 (field `body`). The route has the 415 (`Route.decide`) before.
	## 2. The header `Talon-Contributor`, when there is one: `Hints.machine_id`, 400. (The id comes before the body decode, as R-AP70 rows 5, 6.)
	## 3. `Login.login_token(bytes)`: 400, or the 413 of the body.
	## 4. The rate limit (no D1 call, no GitHub read yet).
	## 5. `Http.send!` of `Request.get(Login.user_url)` with the headers `authorization: Bearer <github_token>`, `accept: application/vnd.github+json` and `user-agent: talon-registry`.
	##    `Err(_)` (no answer) is `Login.user_no_answer`. Else `Login.github_user(status, body)` (the body text only when the status is 200): 401 or 502. The token is never in a log, an error text or a table.
	## 6. `Time.now_ms!()` once. The secrets: `TOKEN_KEY` (`Login.signing_key`) and, when the request has the header, `CONTRIBUTOR_KEY` (the machine id is `Hints.contributor_id` of
	##    `WebCrypto.hmac_sha256(key, Hints.hmac_message(id))`, as `HintRoutes`). The setting `AUDIENCE`. A missing secret or setting, or a bad key, is a `Fault` (500), before any write.
	## 7. The JWT: `Login.signing_input`, `WebCrypto.sign!({ alg: Ed25519, key: Jwk(secret text), data })`, `Login.token_text`.
	## 8. D1 call 1 (the only one): one `batch!` on the primary of `Login.account_sql` and, with the header, `Login.machine_sqls`.
	## 9. 201, `Account.encode_token({ token, expires_at: Login.expires_at(now), account: { id, login } })`.
	post_tokens! : Request => Try(Response, ReadRoutes.Error)
	post_tokens! = |req| {
		bytes = match req.bytes_with!({ max_bytes: Compat.body_limit }) {
			Ok(read) => read
			Err(TooLarge) => return rejected_answer(Login.too_large)
			Err(BodyErr(e)) => return Err(Fault(Str.inspect(e)))
		}
		machine = match req.header("talon-contributor") {
			Ok(text) => Machine(Hints.machine_id(text).map_err(|problem| Refuse(problem))?)
			Err(NotFound) => NoMachine
		}
		github_token = match Login.login_token(bytes) {
			Ok(text) => text
			Err(rejected) => return rejected_answer(rejected)
		}
		match limit!(req)? {
			Limited => return Ok(limited_response())
			Pass => {}
		}
		user = github_user!(github_token)?
		now = Time.now_ms!()
		secret = secret_text!("TOKEN_KEY")?
		key = Login.signing_key(secret).map_err(|_| Fault("TOKEN_KEY is not an Ed25519 key with a kid"))?
		audience = setting!("AUDIENCE")?
		linked = match machine {
			Machine(id) => Linked(machine_text!(id)?)
			NoMachine => Alone
		}
		input = Login.signing_input({ kid: key.kid, sub: user.id, now_ms: now, audience })
		signature = WebCrypto.sign!({ alg: Ed25519, key: Jwk(secret), data: input.to_utf8() }).map_err(|e| Fault(Str.inspect(e)))?
		token = Login.token_text(input, signature)
		account = user.id.to_str()
		at = Sql.Int(now.to_i64_wrap())
		account_stmt = bind(Login.account_sql(), [Sql.Text(account), Sql.Text(user.login), at])
		stmts = match linked {
			Linked(id) => [account_stmt].concat(Login.machine_sqls().map(|sql| bind(sql, [Sql.Text(account), Sql.Text(id), at])))
			Alone => [account_stmt]
		}
		_ = run!(stmts)?
		Ok(json_answer(201, Account.encode_token({ token, expires_at: Login.expires_at(now), account: { id: user.id, login: user.login } })))
	}

	## `DELETE /v1/tokens` (R-AP38, R-CT9). The proof (see the top), no rate limit. D1 call 1 (the only one): `Login.revoke_sql` with the id, `Time.now_ms!()` and `iat_ms`.
	## No row returned: 401 `Login.not_good` (the account has no row, or the token is revoked). 204 otherwise, with `cache-control: no-store`.
	delete_tokens! : Request => Try(Response, ReadRoutes.Error)
	delete_tokens! = |req| {
		proof = request_proof!(req)?
		values = [Sql.Text(proof.who.account.to_str()), Sql.Int(proof.now.to_i64_wrap()), Sql.Int(proof.who.iat_ms.to_i64_wrap())]
		results = run!([bind(Login.revoke_sql(), values)])?
		match results {
			[result] => {
				rows : List({ contributor : Str })
				rows = all(result)?
				if (rows.is_empty()) Err(Refuse(Login.not_good)) else Ok(no_content())
			}
			_ => Err(Fault("login: the revoke batch gave ${results.len().to_str()} results, not 1"))
		}
	}

	## `GET /v1/contributors/me` (R-AP35, R-CT10). The proof, no rate limit. D1 call 1 (the only one): one `batch!` on the primary (Q309) of `Login.account_row_sql` and `Login.tracker_sql`.
	## No account row: 401 `Login.no_account`. `Login.revoked({ iat_ms, tokens_after })`: 401 `Login.revoked_problem`. Else 200 with `Account.encode_tracker(Login.tracker_of(..))`,
	## `content-type: application/json`, `cache-control: no-store`, and no `etag` (Q312).
	get_me! : Request => Try(Response, ReadRoutes.Error)
	get_me! = |req| {
		proof = request_proof!(req)?
		id = [Sql.Text(proof.who.account.to_str())]
		results = run!([bind(Login.account_row_sql(), id), bind(Login.tracker_sql(), id)])?
		match results {
			[account_result, tracker_result] => {
				accounts : List(Login.AccountRow)
				accounts = all(account_result)?
				trackers : List(Login.TrackerRow)
				trackers = all(tracker_result)?
				match (accounts, trackers) {
					([account, ..], [row]) => if Login.revoked({ iat_ms: proof.who.iat_ms, tokens_after: account.tokens_after }) {
						Err(Refuse(Login.revoked_problem))
					} else {
						Ok(json_answer(200, Account.encode_tracker(Login.tracker_of({ id: proof.who.account, login: account.login }, row))))
					}
					([], _) => Err(Refuse(Login.no_account))
					_ => Err(Fault("login: the tracker statement gave ${trackers.len().to_str()} rows, not 1"))
				}
			}
			_ => Err(Fault("login: the tracker batch gave ${results.len().to_str()} results, not 2"))
		}
	}

	## `DELETE /v1/contributors/me` (R-AP36, R-CT7). `Login.delete_proof`: `Refuse(problem)` is the answer.
	## - `Account(text)`: the proof (see the top), then the rate limit, then D1 call 1 (the only one): one `batch!` of `Login.forget_account_sqls` with the id and `iat_ms`. The first result has a row: 401 `Login.not_good`.
	##   An account with no `contributors` row is not an error: the check gives no row, the deletes do nothing, 204 (Q305).
	## - `Machine(id)`: the rate limit, `CONTRIBUTOR_KEY`, the machine id as in `post_tokens!`, D1 call 1: one `batch!` of `Login.forget_machine_sqls`.
	## 204 with `cache-control: no-store`, also when nothing was stored.
	delete_me! : Request => Try(Response, ReadRoutes.Error)
	delete_me! = |req| match Login.delete_proof({ authorization: req.header("authorization"), contributor: req.header("talon-contributor") }) {
		Refuse(problem) => Err(Refuse(problem))
		Account(token) => forget_account!(req, token)
		Machine(id) => forget_machine!(req, id)
	}

	## The account form of the delete: the proof, the limit, then one batch.
	forget_account! : Request, Str => Try(Response, ReadRoutes.Error)
	forget_account! = |req, token| {
		proof = proof!(token)?
		match limit!(req)? {
			Limited => return Ok(limited_response())
			Pass => {}
		}
		values = [Sql.Text(proof.who.account.to_str()), Sql.Int(proof.who.iat_ms.to_i64_wrap())]
		results = run!(Login.forget_account_sqls().map(|sql| bind(sql, values)))?
		match results {
			[check, ..] => {
				revoked : List({ revoked : U64 })
				revoked = all(check)?
				if (revoked.is_empty()) Ok(no_content()) else Err(Refuse(Login.not_good))
			}
			[] => Err(Fault("login: the delete batch gave no result"))
		}
	}

	## The machine form of the delete: the limit (the id was checked by `delete_proof`), the machine id, then one batch.
	forget_machine! : Request, Str => Try(Response, ReadRoutes.Error)
	forget_machine! = |req, id| {
		match limit!(req)? {
			Limited => return Ok(limited_response())
			Pass => {}
		}
		machine = machine_text!(id)?
		_ = run!(Login.forget_machine_sqls().map(|sql| bind(sql, [Sql.Text(machine)])))?
		Ok(no_content())
	}

	## The proof of an account route from the header `Authorization` (`Oidc.bearer`).
	request_proof! : Request => Try(LoginRoutes.Proof, ReadRoutes.Error)
	request_proof! = |req| match Oidc.bearer(req.header("authorization")) {
		Token(text) => proof!(text)
		NoToken => Err(Refuse(Login.missing_token))
		Refuse(problem) => Err(Refuse(problem))
	}

	## The proof of a token text (R-CT9): the key, the form and the `kid`, the signature, then the claims against the setting `AUDIENCE` and the clock. No D1 call.
	proof! : Str => Try(LoginRoutes.Proof, ReadRoutes.Error)
	proof! = |token| {
		secret = secret_text!("TOKEN_KEY")?
		key = Login.signing_key(secret).map_err(|_| Fault("TOKEN_KEY is not an Ed25519 key with a kid"))?
		decoded = Login.decode(token, key.kid).map_err(|problem| Refuse(problem))?
		WebCrypto.verify!({ alg: Ed25519, key: Jwk(key.public_json), signature: decoded.signature, data: decoded.signing_input }).map_err(|_| Refuse(Login.bad_signature))?
		audience = setting!("AUDIENCE")?
		now = Time.now_ms!()
		who = Login.check(decoded, { audience, now_ms: now }).map_err(|problem| Refuse(problem))?
		Ok({ who, now })
	}

	## The rate limit (R-CT11, Q308): `Limited` when the key is over the budget. A fault of the binding is a `Fault`.
	limit! : Request => Try([Pass, Limited], ReadRoutes.Error)
	limit! = |req| match limiter.limit!(Client.rate_key(req.header("cf-connecting-ip"))) {
		Ok({}) => Ok(Pass)
		Err(RateLimited) => Ok(Limited)
		Err(Infra(e)) => Err(Fault(Str.inspect(e)))
	}

	## The 429 of the limit: `Retry-After` is the period of the binding.
	limited_response : () -> Response
	limited_response = || {
		problem = Login.rate_problem
		Response.from_bytes(problem.http_status(), "application/problem+json", problem.to_json().to_utf8()).with_header("retry-after", Client.limit_retry_after.to_str())
	}

	## A refused login body: the 400, or the 413 with the members `field` and `limit`.
	rejected_answer : Compat.Reject -> Try(Response, ReadRoutes.Error)
	rejected_answer = |rejected| match rejected {
		Bad(problem) => Err(Refuse(problem))
		TooLarge(problem, extra) => Ok(Response.from_bytes(413, "application/problem+json", Problem.to_json_with(problem, extra).to_utf8()))
	}

	## R-CT8 row 2: the GitHub read of the user, with the token of the user (not the token of the App). 401 and 502 are `Refuse`.
	github_user! : Str => Try(Login.GithubUser, ReadRoutes.Error)
	github_user! = |github_token| {
		request = Request.get(Login.user_url).with_header("authorization", "Bearer ${github_token}").with_header("accept", "application/vnd.github+json").with_header("user-agent", "talon-registry")
		res = Http.send!(request).map_err(|_| Refuse(Login.user_no_answer))?
		status = res.status()
		body = if (status == 200) res.text!() ?? "" else ""
		Login.github_user(status, body).map_err(|problem| Refuse(problem))
	}

	## The machine id of R-CT3 as a decimal text (R-IK2): `Hints.contributor_id` of the HMAC of the id with the secret `CONTRIBUTOR_KEY`.
	machine_text! : Str => Try(Str, ReadRoutes.Error)
	machine_text! = |id| {
		secret = secret_text!("CONTRIBUTOR_KEY")?
		Ok(Hints.contributor_id(WebCrypto.hmac_sha256(secret.to_utf8(), Hints.hmac_message(id))).to_str())
	}

	## A secret as text. A missing secret is a `Fault`.
	secret_text! : Str => Try(Str, ReadRoutes.Error)
	secret_text! = |name| Env.secret!(name).map_ok(|secret| secret.reveal()).map_err(|e| Fault(Str.inspect(e)))

	## A setting. A missing setting is a `Fault`.
	setting! : Str => Try(Str, ReadRoutes.Error)
	setting! = |name| Env.var!(name).map_err(|e| Fault(Str.inspect(e)))

	## A statement with the first values of the list: as many as its highest `?n` (D1 refuses more or fewer).
	bind : Str, List(Sql) -> Sql.Stmt
	bind = |sql, values| Sql.stmt(sql, values.take_first(Login.arity(sql)))

	## One batch on the primary. A `Constraint` error is a fault, as every other error of D1.
	run! : List(Sql.Stmt) => Try(List(D1.Result), ReadRoutes.Error)
	run! = |stmts| db.batch!(stmts).map_err(|e| Fault(Str.inspect(e)))

	all = |result| result.all().map_err(|e| Fault(Str.inspect(e)))

	## 200 or 201 with a JSON body. `no-store` (R-AP24 exception, Q312).
	json_answer : U16, Str -> Response
	json_answer = |status, body| Response.from_bytes(status, "application/json", body.to_utf8()).with_header("cache-control", "no-store")

	## 204, no body.
	no_content : () -> Response
	no_content = || Response.from_status(204).with_header("cache-control", "no-store")
}
