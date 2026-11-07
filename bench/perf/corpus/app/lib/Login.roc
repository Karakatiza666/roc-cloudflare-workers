## The pure part of the account routes: login, the JWT, the tracker and the delete (Registry 4: R-AP35 to R-AP38, R-AP41, R-AP46, R-AP48, R-AP51; 6.1: R-CT7 to R-CT11; 5: R-RE17, R-RE18, R-RE25; 8: R-WH14; slice 117).
## No effect, no platform import. The effects (the body read, the GitHub read, WebCrypto, the D1 calls, the clock, the rate limit) are in `worker/LoginRoutes.roc`.
## The tests are `worker/tests/unit/LoginTest.roc` (W0) and `worker/tests/cases/account/` (W2). The slice file is `docs/slices/117-login.md`: it is the only link to the test agent (TW18).
## The `detail` texts, the form of the JWT parts, the setting formats and the SQL texts are proposals for the human review (TW24) or questions (TW17): the slice file sections 6 and 9.
## The ids of accounts and machines are bound as decimal text with `CAST(?n AS INTEGER)` in the SQL (64-bit values, R-IK2), as `Hints`. Times are bound as numbers (ms).
## A statement is bound with as many values as its highest `?n` (D1 refuses more or fewer): a statement that uses only `?2` gets 2 values.
import records.Account
import jwt.Jwt
import jwt.Jwk
import Compat
import Hints
import Oidc
import Problem

Login :: [].{

	## R-CT9: a token lives 30 days, in ms.
	token_ttl_ms : U64
	token_ttl_ms = 2_592_000_000

	## R-CT8 row 2: the GitHub read of the account (`GET` with the token of the user).
	user_url : Str
	user_url = "https://api.github.com/user"

	## R-WH14 (proposal): the rate limit binding of `POST /v1/tokens` and `DELETE /v1/contributors/me`, 10 a minute for each rate key (R-CT11). `Retry-After` is its period, 60 s (as `Client.limit_retry_after`).
	limit_binding : Str
	limit_binding = "RL_LOGIN"

	## R-CT9: the `alg` allowlist of the Worker JWT. Only `EdDSA`: a GitHub OIDC token (RS256) with the same `aud` is not an account token.
	algs : List(Jwt.Alg)
	algs = [EdDSA]

	## The most bytes of a GitHub token (Q303). A longer one is 400.
	token_max_bytes : U64
	token_max_bytes = 512

	## R-AP46 row 1: the 413 of a body above `Compat.body_limit` bytes, field `body`. `detail`: `the body of the login request is larger than its limit of 262144`.
	## The route gives it when `Request.bytes_with!` refuses the body, and `login_token` gives it for a body of more bytes.
	too_large : Compat.Reject
	too_large = TooLarge(Problem.new(TooLarge, "the body of the login request is larger than its limit of 262144"), { field: "body", limit: 262_144 })

	## R-AP37 request, R-AP46 row 1, R-AP51, R-CT16 row 1 (Q303): the body `{"github_token": ".."}`, in this order. The first check that fails gives the answer.
	## 1. More than `Compat.body_limit` bytes: 413, field `body`, limit 262144. `detail`: `the body of the login request is larger than its limit of 262144`.
	## 2. The body is not UTF-8, not JSON, not an object, `github_token` is missing or `null` or not a text (R-AP51), or the text is empty, longer than `token_max_bytes` bytes, or has a
	##    byte that is not `!` to `~` (a space, a control character or a byte above 126 could not go in a header): 400 `bad-request`.
	##    `detail`: `the login request body is not valid: <why>`. For a missing member `<why>` names it (`github_token`). Another member is ignored (R-AP44).
	##    The `detail` never holds the token.
	## `Ok(token)` is the text of `github_token`.
	login_token : List(U8) -> Try(Str, Compat.Reject)
	login_token = |body| {
		if body.len() > Compat.body_limit {
			return Err(too_large)
		}
		text = Str.from_utf8(body).map_err(|_| refused_login("it is not UTF-8"))?
		parsed : Try(RawLogin, _)
		parsed = Json.parse(text)
		raw = parsed.map_err(|_| refused_login("it is not a JSON object with the member github_token"))?
		token = raw.github_token.map_err(|Missing| refused_login("github_token is missing"))?
		bytes = token.to_utf8()
		if bytes.is_empty() {
			Err(refused_login("github_token is empty"))
		} else if bytes.len() > token_max_bytes {
			Err(refused_login("github_token is longer than ${token_max_bytes.to_str()} bytes"))
		} else if !bytes.all(|b| b >= '!' and b <= '~') {
			Err(refused_login("github_token has a byte that is not allowed in a token"))
		} else {
			Ok(token)
		}
	}

	## The member of the login body that this module reads (R-AP44: another member is ignored). A missing member is `Err(Missing)`.
	RawLogin : { github_token : Try(Str, [Missing]) }

	## The 400 of a login body, with the reason. The reason never holds the token.
	refused_login : Str -> Compat.Reject
	refused_login = |why| Bad(Problem.new(BadRequest, "the login request body is not valid: ${why}"))

	## R-CT8 row 2: what the Worker keeps of the GitHub answer: the id (an integer above 0) and the login.
	GithubUser : { id : U64, login : Str }

	## R-CT8 rows 2, 4, R-AP37: the answer of `GET user_url` as a pure decision. `body` is the body text (the route passes the empty text when the status is not 200).
	## 1. Status 200 and a body that is a JSON object with an integer `id` above 0 and a text `login` that is not empty: `Ok`. Other members are ignored.
	## 2. Status 401: `Err(user_refused)`.
	## 3. Any other status, or status 200 with a body that is not that (not JSON, no `id`, `id` 0, no `login`, an empty `login`): `Err` 502 `upstream`,
	##    `detail`: `the GitHub user read failed with status <status>` (for status 200 and a bad body: `the GitHub user read gave an answer that is not a user`).
	## Status 403 and 429 are 502 too: GitHub refuses the token only with 401 (Q304).
	github_user : U16, Str -> Try(Login.GithubUser, Problem)
	github_user = |status, body| {
		if status == 401 {
			Err(user_refused)
		} else if status != 200 {
			Err(Problem.new(Upstream, "the GitHub user read failed with status ${status.to_str()}"))
		} else {
			parsed : Try(Login.GithubUser, _)
			parsed = Json.parse(body)
			match parsed {
				Ok(user) if user.id > 0 and !user.login.is_empty() => Ok(user)
				_ => Err(Problem.new(Upstream, "the GitHub user read gave an answer that is not a user"))
			}
		}
	}

	## R-CT8 row 4: GitHub refuses the token. 401 `unauthenticated`, `detail`: `GitHub refused the token`.
	user_refused : Problem
	user_refused = Problem.new(Unauthenticated, "GitHub refused the token")

	## R-CT8 row 4: GitHub does not answer. 502 `upstream`, `detail`: `the GitHub user read failed: no answer`.
	user_no_answer : Problem
	user_no_answer = Problem.new(Upstream, "the GitHub user read failed: no answer")

	## R-CT11, R-CT16 row 9 (Q308): the 429 of `RL_LOGIN`. `detail`: `too many login requests from this address: try again in a minute`.
	rate_problem : Problem
	rate_problem = Problem.new(RateLimited, "too many login requests from this address: try again in a minute")

	## R-AP26-like 401 of an account route with no `Authorization` header. `detail`: `the request has no Authorization header: this route needs a registry token`.
	missing_token : Problem
	missing_token = Problem.new(Unauthenticated, "the request has no Authorization header: this route needs a registry token")

	## The 401 of a signature that `WebCrypto.verify!` refuses. `detail`: `the token signature is not valid`.
	bad_signature : Problem
	bad_signature = Problem.new(Unauthenticated, "the token signature is not valid")

	## R-CT9, R-RE17, R-CT16 row 4 (Q305): the token is valid, but its account has no `contributors` row (never logged in here, or deleted by R-CT7). 401,
	## `detail`: `the account of the token has no data in this registry: log in again`.
	no_account : Problem
	no_account = Problem.new(Unauthenticated, "the account of the token has no data in this registry: log in again")

	## R-CT9: the token was issued before `tokens_after` of its account. 401, `detail`: `the token was issued before the last revoke of the tokens of its account: log in again`.
	revoked_problem : Problem
	revoked_problem = Problem.new(Unauthenticated, "the token was issued before the last revoke of the tokens of its account: log in again")

	## R-AP38, R-CT7 (Q305): the 401 of a route that checks the token in SQL (`DELETE /v1/tokens`, the account form of `DELETE /v1/contributors/me`) when the guard stops the statement: the token is revoked,
	## or (for `DELETE /v1/tokens`) the account has no row. `detail`: `the token is revoked or its account has no data in this registry: log in again`.
	not_good : Problem
	not_good = Problem.new(Unauthenticated, "the token is revoked or its account has no data in this registry: log in again")

	## R-CT9, Q300: the secret `TOKEN_KEY` is the private JWK of an Ed25519 key as JSON text: `kty` `OKP`, `crv` `Ed25519`, `x`, `d`, and `kid` (the id of the key, R-CT9).
	## `public_json` is the public JWK for `WebCrypto.verify!` (`Jwk.to_public_json`, no `d`). `Ok` needs a JWK that `Jwk.parse` reads as an Ed25519 key, with a `kid` that is not empty.
	## A text that is not JSON, another `kty` or `crv`, a missing `x` or `kid`, or an empty `kid` is `Err(BadKey)`: the route answers 500 `internal`.
	## The route signs with the secret text as the key (`Jwk(text)`), so a key with no `d` fails at the sign, also 500.
	SigningKey : { kid : Str, public_json : Str }

	signing_key : Str -> Try(Login.SigningKey, [BadKey])
	signing_key = |text| {
		key = Jwk.parse(text).map_err(|_| BadKey)?
		kid = match key.kid {
			Ok(found) if !found.is_empty() => found
			_ => return Err(BadKey)
		}
		match key.material {
			Okp({ crv: Ed25519, x: _ }) => Ok({ kid, public_json: Jwk.to_public_json(key) })
			_ => Err(BadKey)
		}
	}

	## R-CT9, Q301: the text of a number of ms as seconds with 3 decimals: `1767225601234` is `1767225601.234`, `1767225600000` is `1767225600.000`, `5` is `0.005`.
	## An `iat` with a fraction of a second keeps the order of a login and a `DELETE /v1/tokens` inside one second (R-CT9: `iat` not before `tokens_after`, in ms).
	seconds_text : U64 -> Str
	seconds_text = |ms| {
		fraction = ms % 1000
		pad = if (fraction < 10) "00" else if (fraction < 100) "0" else ""
		"${(ms // 1000).to_str()}.${pad}${fraction.to_str()}"
	}

	## R-CT9: the signing input of a new token, `base64url(header) "." base64url(payload)`, with no `=` (RFC 7515).
	## header: `{"alg":"EdDSA","kid":<kid>,"typ":"JWT"}`. payload (members in this order): `{"aud":<audience>,"exp":<iat + 30 days>,"iat":<now>,"iss":<audience>,"sub":"<sub>"}`.
	## `iat` is `seconds_text(now_ms)` and `exp` is `seconds_text(now_ms + token_ttl_ms)`, both as JSON numbers. `sub` is the GitHub user id as a JSON text. `iss` and `aud` are both `audience` (the setting `AUDIENCE`).
	## `kid` and `audience` are JSON-escaped.
	signing_input : { kid : Str, sub : U64, now_ms : U64, audience : Str } -> Str
	signing_input = |x| {
		header = "{\"alg\":\"EdDSA\",\"kid\":${Json.to_str(x.kid)},\"typ\":\"JWT\"}"
		exp = seconds_text(expires_at(x.now_ms))
		iat = seconds_text(x.now_ms)
		aud = Json.to_str(x.audience)
		payload = "{\"aud\":${aud},\"exp\":${exp},\"iat\":${iat},\"iss\":${aud},\"sub\":\"${x.sub.to_str()}\"}"
		"${base64url(header.to_utf8())}.${base64url(payload.to_utf8())}"
	}

	## base64url (RFC 4648 5) of bytes, with no `=`. `roc-jwt` has an encoder, but its app header does not name `roc-base64`.
	base64url : List(U8) -> Str
	base64url = |bytes| {
		table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".to_utf8()
		var $out = []
		for chunk in bytes.chunks_of(3) {
			b0 = (chunk.get(0) ?? 0).to_u32()
			b1 = (chunk.get(1) ?? 0).to_u32()
			b2 = (chunk.get(2) ?? 0).to_u32()
			v = b0 * 65536 + b1 * 256 + b2
			digits = [v // 262144, v // 4096 % 64, v // 64 % 64, v % 64]
			keep = chunk.len() + 1
			for i in 0.U64..<keep {
				$out = $out.append(table.get((digits.get(i) ?? 0).to_u64()) ?? '=')
			}
		}
		Str.from_utf8($out) ?? ""
	}

	## The token text: `input` (the signing input), `.`, and `base64url(signature)` with no `=`.
	token_text : Str, List(U8) -> Str
	token_text = |input, signature| "${input}.${base64url(signature)}"

	## R-AP37 answer: `expires_at` is `now_ms + token_ttl_ms`, the `exp` of the token in ms (R-AP50).
	expires_at : U64 -> U64
	expires_at = |now_ms| now_ms + token_ttl_ms

	## A token after `decode`: the signature is not checked yet. Use `claims` only after `WebCrypto.verify!` is `Ok` and `check` is `Ok`.
	Decoded : { claims : Jwt.Claims, signing_input : List(U8), signature : List(U8) }

	## R-CT9 form: `Jwt.decode(text, Jwt.Options.{ algs })` (the default `max_token_bytes`), then the `kid` (Q300): the header must have a `kid` equal to `kid`. Each fault is 401 `unauthenticated`:
	## - an error of `Jwt.decode`: `jwt_problem(err, "")`
	## - no `kid` in the header: `the token kid is missing`
	## - another `kid`: `the token kid "<kid>" is not the key of this registry`
	## No D1 call and no crypto are needed for these.
	decode : Str, Str -> Try(Login.Decoded, Problem)
	decode = |text, kid| {
		token = Jwt.decode(text, Jwt.Options.{ algs }).map_err(|err| jwt_problem(err, ""))?
		match token.header.kid {
			Err(Missing) => Err(Problem.new(Unauthenticated, "the token kid is missing"))
			Ok(found) if found != kid => Err(Problem.new(Unauthenticated, "the token kid \"${found}\" is not the key of this registry"))
			Ok(_) => Ok({ claims: token.claims, signing_input: token.signing_input, signature: token.signature })
		}
	}

	## The 401 of a `Jwt.Error` (the `detail` texts of `Oidc.jwt_problem`, except the `alg` rows):
	## - `AlgMissing`: `the token alg is missing`. `AlgNone`: `the token alg is "none", expected "EdDSA"`. `AlgNotAllowed(alg)`: `the token alg is "<alg>", expected "EdDSA"`.
	## - a malformed token (`TooLong`, `NotCompact`, `BadBase64`, `BadUtf8`, `BadJson`, `CritUnsupported`, `EmptySignature`, `BadSignatureLength`): `the token is not a valid JWT`
	## - a claim error: the texts of `Oidc.jwt_detail` (`token claim exp is <exp>: the token expired (now is <now>, leeway 60 s)`, `token claim iss is "<iss>", expected "<audience>"`, ...). `audience` is the setting.
	jwt_problem : Jwt.Error, Str -> Problem
	jwt_problem = |err, audience| match err {
		AlgNone => Problem.new(Unauthenticated, "the token alg is \"none\", expected \"EdDSA\"")
		AlgNotAllowed(alg) => Problem.new(Unauthenticated, "the token alg is \"${alg}\", expected \"EdDSA\"")
		WrongIssuer(iss) => Problem.new(Unauthenticated, "token claim iss is \"${iss}\", expected \"${audience}\"")
		_ => Oidc.jwt_problem(err, audience)
	}

	## What a good token proves: the GitHub user id (`sub`) and `iat` in whole ms.
	Verified : { account : U64, iat_ms : U64 }

	## R-CT9 claims, after the signature: `Jwt.check(claims, Jwt.Rules.{ now_ms, aud: OneOf([audience]), iss: OneOf([audience]), require: [Exp, Iat, Sub] })` with `leeway_s` 60 (Q301, as R-TP3 row 3), so a token is good when
	## `now - 60 < exp` and `iat <= now + 60` (times in seconds, `now` is `now_ms / 1000`; an `iat` more than 60 s in the future is refused). The leeway is not in `revoked`. A fault is `jwt_problem(err, audience)`. Then `sub` (R-CT16 row 6) must be the text of an integer above 0 with digits only
	## (`4242`; `0`, `-5`, `12.5`, `abc`, `+7` and an empty text are refused): 401, `detail`: `token claim sub is "<sub>", expected a GitHub user id`.
	## `iat_ms` is `iat * 1000` rounded down.
	check : Login.Decoded, { audience : Str, now_ms : U64 } -> Try(Login.Verified, Problem)
	check = |decoded, x| {
		rules = Jwt.Rules.{ now_ms: x.now_ms, aud: OneOf([x.audience]), iss: OneOf([x.audience]), leeway_s: 60, require: [Exp, Iat, Sub] }
		Jwt.check(decoded.claims, rules).map_err(|err| jwt_problem(err, x.audience))?
		sub = decoded.claims.sub.map_err(|Missing| jwt_problem(MissingClaim(Sub), x.audience))?
		account = user_id(sub)?
		iat = decoded.claims.iat.map_err(|Missing| jwt_problem(MissingClaim(Iat), x.audience))?
		millis = (iat * 1000).floor_to_i128()
		iat_ms = if (millis < 0) 0 else millis.to_u64_wrap()
		Ok({ account, iat_ms })
	}

	## R-CT16 row 6: `sub` is the text of an integer above 0, with digits only.
	user_id : Str -> Try(U64, Problem)
	user_id = |sub| {
		refused = Problem.new(Unauthenticated, "token claim sub is \"${sub}\", expected a GitHub user id")
		if sub.to_utf8().all(|b| b >= '0' and b <= '9') {
			match U64.from_str(sub) {
				Ok(id) if id > 0 => Ok(id)
				_ => Err(refused)
			}
		} else {
			Err(refused)
		}
	}

	## R-CT9: is a token revoked? `iat_ms` before `tokens_after` of the account. `iat_ms == tokens_after` is good (a login in the same ms as a revoke works).
	revoked : { iat_ms : U64, tokens_after : U64 } -> Bool
	revoked = |x| x.iat_ms < x.tokens_after

	## R-AP36, R-CT7, R-CT16 row 7 (Q306): the proof of `DELETE /v1/contributors/me`, from the two headers.
	## 1. A header `Authorization` (any value): the account form. `Oidc.bearer`: `Token(text)` is `Account(text)`; a header that is not `Bearer <token>` is `Refuse` (401, the `detail` of `Oidc.bearer`).
	##    The header `Talon-Contributor` is then ignored (as R-CT1: a token wins).
	## 2. No `Authorization` and a header `Talon-Contributor`: `Hints.machine_id`. `Ok(id)` is `Machine(id)`, `Err(problem)` is `Refuse(problem)` (400, the `detail` of `Hints.machine_id`).
	## 3. Neither: `Refuse` 400 `bad-request`, `detail`: `the request needs the header Authorization (an account) or the header Talon-Contributor (one machine)`.
	delete_proof : { authorization : Try(Str, [NotFound]), contributor : Try(Str, [NotFound]) } -> [Account(Str), Machine(Str), Refuse(Problem)]
	delete_proof = |x| match x.authorization {
		Ok(_) => match Oidc.bearer(x.authorization) {
			Token(text) => Account(text)
			NoToken => Refuse(missing_token)
			Refuse(problem) => Refuse(problem)
		}
		Err(NotFound) => match x.contributor {
			Ok(id) => match Hints.machine_id(id) {
				Ok(machine) => Machine(machine)
				Err(problem) => Refuse(problem)
			}
			Err(NotFound) => Refuse(Problem.new(BadRequest, "the request needs the header Authorization (an account) or the header Talon-Contributor (one machine)"))
		}
	}

	## R-CT8 row 3, step 1, R-CT16 row 5 (Q307): the upsert of the account. Parameters: ?1 the id (text), ?2 the login, ?3 now (ms).
	## A new row: `tokens_after` is ?3 (not 0: a token issued before the row was made, for example before a delete by R-CT7, is never good), `first_time` and `last_time` are ?3.
	## An existing row: `login` and `last_time` change; `tokens_after` and `first_time` never change. `ON CONFLICT ... DO UPDATE`, never `INSERT OR REPLACE`.
	account_sql : () -> Str
	account_sql = || sql_text([
		"INSERT INTO contributors (contributor, login, tokens_after, first_time, last_time)",
		"VALUES (CAST(?1 AS INTEGER), ?2, ?3, ?3, ?3)",
		"ON CONFLICT (contributor) DO UPDATE SET login = excluded.login, last_time = MAX(contributors.last_time, excluded.last_time)",
	])

	## One SQL text from lines.
	sql_text : List(Str) -> Str
	sql_text = |lines| Str.join_with(lines, " ")

	## How many values a statement takes: the highest `?n` in its text (D1 refuses more or fewer values).
	arity : Str -> U64
	arity = |sql| sql.split_on("?").drop_first(1).fold(
		0,
		|top, part| {
			n = leading_number(part)
			if (n > top) n else top
		},
	)

	## The number that a text starts with (0 when it starts with no digit).
	leading_number : Str -> U64
	leading_number = |part| {
		var $n = 0.U64
		for b in part.to_utf8() {
			if b >= '0' and b <= '9' {
				$n = $n * 10 + (b - '0').to_u64()
			} else {
				break
			}
		}
		$n
	}

	## R-CT8 row 3, the machine part, in this order. Parameters of each statement: ?1 the account id (text), ?2 the machine id (text), ?3 now (ms). Only for a login with a `Talon-Contributor` header.
	## 1. The upsert of `links`: the machine to the account, `time` ?3 (a later login of the machine with another account moves the link).
	## 2. `UPDATE OR IGNORE contributions SET contributor = account WHERE contributor = machine` (a pair that the account has already stays with the account).
	## 3. `DELETE FROM contributions WHERE contributor = machine` (the pairs that stayed).
	## 4. The `contributor_totals` of the machine are added to those of the account: `counted`, `first`, `agreed`, `disagreed`, `unconfirmed` are summed, `first_time` is the smaller, `last_time` is the larger (Q302). A row of the account is made when it has none.
	## 5. `DELETE FROM contributor_totals WHERE contributor = machine`.
	## No statement fires the trigger `contributions_count` (an `UPDATE` is not an `INSERT`), so no count changes.
	machine_sqls : () -> List(Str)
	machine_sqls = || [
		sql_text([
			"INSERT INTO links (machine, contributor, time) VALUES (CAST(?2 AS INTEGER), CAST(?1 AS INTEGER), ?3)",
			"ON CONFLICT (machine) DO UPDATE SET contributor = excluded.contributor, time = excluded.time",
		]),
		"UPDATE OR IGNORE contributions SET contributor = CAST(?1 AS INTEGER) WHERE contributor = CAST(?2 AS INTEGER)",
		"DELETE FROM contributions WHERE contributor = CAST(?2 AS INTEGER)",
		sql_text([
			"INSERT INTO contributor_totals (contributor, counted, first, agreed, disagreed, unconfirmed, first_time, last_time)",
			"SELECT CAST(?1 AS INTEGER), counted, first, agreed, disagreed, unconfirmed, first_time, last_time FROM contributor_totals WHERE contributor = CAST(?2 AS INTEGER)",
			"ON CONFLICT (contributor) DO UPDATE SET counted = contributor_totals.counted + excluded.counted, first = contributor_totals.first + excluded.first,",
			"agreed = contributor_totals.agreed + excluded.agreed, disagreed = contributor_totals.disagreed + excluded.disagreed,",
			"unconfirmed = contributor_totals.unconfirmed + excluded.unconfirmed,",
			"first_time = MIN(contributor_totals.first_time, excluded.first_time), last_time = MAX(contributor_totals.last_time, excluded.last_time)",
		]),
		"DELETE FROM contributor_totals WHERE contributor = CAST(?2 AS INTEGER)",
	]

	## The row of the account (R-RE17): `SELECT login, tokens_after FROM contributors WHERE contributor = CAST(?1 AS INTEGER)`: ?1 the id (text). 0 or 1 row.
	AccountRow : { login : Str, tokens_after : U64 }

	account_row_sql : () -> Str
	account_row_sql = || "SELECT login, tokens_after FROM contributors WHERE contributor = CAST(?1 AS INTEGER)"

	## R-CT10: the tracker of the account, one row. Parameters: ?1 the id (text). Columns: `machines`, `counted`, `first`, `agreed`, `disagreed`, `unconfirmed` (integers), `first_time`, `last_time` (integers or NULL).
	## From the `contributions` rows of the account, plus the `contributor_totals` row of the account (when there is one):
	## - `machines`: the count of `links` rows to the account.
	## - `counted`: the rows, plus `counted` of the totals.
	## - `first`: rows of the pair that have no `compat` row (any source) with `time` below the row's `time`, and no row of another contributor with `time` below it, or with the same `time` and a smaller contributor id.
	##   Plus `first` of the totals.
	## - `agreed`: rows of the pair that have a `compat` row with `source` 0 (`bot`) and the same `result`. `disagreed`: a `bot` row with another `result` (a bot `hang` is another result). `unconfirmed`: no `bot` row.
	##   Each plus its total.
	## - `first_time`: the smallest `time` of the rows and `first_time` of the totals. `last_time`: the larger of the largest `time` of the rows and `last_time` of the totals (Q302). NULL when there is none.
	## An account with no rows and no totals: all counts 0 (`machines` as it is) and both times NULL.
	TrackerRow : {
		machines : U64,
		counted : U64,
		first : U64,
		agreed : U64,
		disagreed : U64,
		unconfirmed : U64,
		first_time : Try(U64, [Missing]),
		last_time : Try(U64, [Missing]),
	}

	tracker_sql : () -> Str
	tracker_sql = || sql_text([
		"WITH mine AS (SELECT artifact, nightly, target, result, time, contributor FROM contributions WHERE contributor = CAST(?1 AS INTEGER)),",
		"judged AS (SELECT m.time AS seen, m.result AS result,",
		"(NOT EXISTS (SELECT 1 FROM compat x WHERE x.artifact = m.artifact AND x.nightly = m.nightly AND x.target = m.target AND x.time < m.time)",
		"AND NOT EXISTS (SELECT 1 FROM contributions o WHERE o.artifact = m.artifact AND o.nightly = m.nightly AND o.target = m.target AND o.contributor <> m.contributor",
		"AND (o.time < m.time OR (o.time = m.time AND o.contributor < m.contributor)))) AS is_first,",
		"(SELECT b.result FROM compat b WHERE b.artifact = m.artifact AND b.nightly = m.nightly AND b.target = m.target AND b.source = 0) AS bot",
		"FROM mine m),",
		"agg AS (SELECT COUNT(*) AS n, COALESCE(SUM(is_first), 0) AS firsts, COALESCE(SUM(bot IS NOT NULL AND bot = result), 0) AS agreed,",
		"COALESCE(SUM(bot IS NOT NULL AND bot <> result), 0) AS disagreed, COALESCE(SUM(bot IS NULL), 0) AS unconfirmed,",
		"MIN(seen) AS first_time, MAX(seen) AS last_time FROM judged)",
		"SELECT (SELECT COUNT(*) FROM links WHERE contributor = CAST(?1 AS INTEGER)) AS machines,",
		"agg.n + COALESCE(t.counted, 0) AS counted, agg.firsts + COALESCE(t.first, 0) AS first, agg.agreed + COALESCE(t.agreed, 0) AS agreed,",
		"agg.disagreed + COALESCE(t.disagreed, 0) AS disagreed, agg.unconfirmed + COALESCE(t.unconfirmed, 0) AS unconfirmed,",
		"COALESCE(MIN(agg.first_time, t.first_time), agg.first_time, t.first_time) AS first_time,",
		"COALESCE(MAX(agg.last_time, t.last_time), agg.last_time, t.last_time) AS last_time",
		"FROM agg LEFT JOIN contributor_totals t ON t.contributor = CAST(?1 AS INTEGER)",
	])

	## R-AP35: the tracker of the answer, from the GitHub id, the login of the `contributors` row and the tracker row. `Missing` is `null` on the wire.
	tracker_of : Login.GithubUser, Login.TrackerRow -> Account.Tracker
	tracker_of = |who, row| {
		first_time = row.first_time.map_err(|Missing| None)
		last_time = row.last_time.map_err(|Missing| None)
		{ account: who, machines: row.machines, counted: row.counted, first: row.first, agreed: row.agreed, disagreed: row.disagreed, unconfirmed: row.unconfirmed, first_time, last_time }
	}

	## R-AP38, R-CT9: one statement. Parameters: ?1 the id (text), ?2 now (ms), ?3 `iat_ms` of the token. `UPDATE contributors SET tokens_after = ?2 WHERE contributor = ?1 AND tokens_after <= ?3 RETURNING`
	## one column: it returns 1 row when the token is good, and 0 rows when the account has no row or the token is revoked (401).
	revoke_sql : () -> Str
	revoke_sql = || "UPDATE contributors SET tokens_after = ?2 WHERE contributor = CAST(?1 AS INTEGER) AND tokens_after <= ?3 RETURNING CAST(contributor AS TEXT) AS contributor"

	## R-CT7, account form, in this order (one D1 batch). Parameters: ?1 the id (text), ?2 `iat_ms` of the token.
	## 1. `SELECT 1 AS revoked`: one row when the account has a row with `tokens_after` above ?2 (the token is revoked: 401), else no row.
	## 2 to 5. `DELETE` of the `contributions` rows, the `links` rows to the account, the `contributor_totals` row and the `contributors` row of the account. Each statement does nothing when the check of 1 gives a row:
	##    `AND NOT EXISTS (SELECT 1 FROM contributors g WHERE g.contributor = account AND g.tokens_after > ?2)`. So a revoked token deletes nothing, with no second D1 call.
	## `compat_hints` is never changed (R-CT7).
	forget_account_sqls : () -> List(Str)
	forget_account_sqls = || {
		guard = "AND NOT EXISTS (SELECT 1 FROM contributors g WHERE g.contributor = CAST(?1 AS INTEGER) AND g.tokens_after > ?2)"
		[
			"SELECT 1 AS revoked FROM contributors WHERE contributor = CAST(?1 AS INTEGER) AND tokens_after > ?2",
			"DELETE FROM contributions WHERE contributor = CAST(?1 AS INTEGER) ${guard}",
			"DELETE FROM links WHERE contributor = CAST(?1 AS INTEGER) ${guard}",
			"DELETE FROM contributor_totals WHERE contributor = CAST(?1 AS INTEGER) ${guard}",
			"DELETE FROM contributors WHERE contributor = CAST(?1 AS INTEGER) ${guard}",
		]
	}

	## R-CT7, machine form, in this order (one D1 batch). Parameter: ?1 the machine id (text). `DELETE` of the `contributions` rows of the machine, its `contributor_totals` row and its `links` row.
	## The rows of the account that the machine is linked to stay.
	forget_machine_sqls : () -> List(Str)
	forget_machine_sqls = || [
		"DELETE FROM contributions WHERE contributor = CAST(?1 AS INTEGER)",
		"DELETE FROM contributor_totals WHERE contributor = CAST(?1 AS INTEGER)",
		"DELETE FROM links WHERE machine = CAST(?1 AS INTEGER)",
	]
}
