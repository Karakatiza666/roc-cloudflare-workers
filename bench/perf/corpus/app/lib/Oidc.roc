## The pure part of the GitHub OIDC token check (Registry 7.1, R-TP1 to R-TP4, R-TP7, R-AP26; slice 108). No effect, no platform import.
## The effects (the JWKS read through `Memo`, the RS256 verify with `WebCrypto.verify!`, the clock, the settings) are in `worker/Auth.roc`.
## The tests are in `worker/tests/unit/OidcTest.roc` (W0) and `worker/tests/cases/oidc/` (W2).
## Each check gives the first failing row as a `Problem`: 401 `Unauthenticated` for R-TP3 rows 1 to 3, 403 `Forbidden` for the other rows
## and for R-TP7 (R-AP21). The `detail` texts are in `docs/slices/108-oidc.md` section 5 (proposal, TW24):
##   a claim with a wrong value:  token claim <name> is "<value>", expected "<want>"   (numbers with no quotes)
##   a claim that is missing:     token claim <name> is missing
import Problem
import jwt.Jwt
import jwt.Jwk

Oidc :: [].{

	## Slice 108b (`docs/slices/108b-roc-jwt.md`): the token form, base64url, the JWKS parse, the key select and the registered claim checks move to
	## the generic package `roc-jwt` 0.0.1 (Design R-PK9): `Token`, `KeySet`, `algs`, `decode`, `key_for`, `check_registered` and `jwt_problem`
	## use it.
	## The Talon rules stay here: `bearer`, `kid` required, the `alg` RS256, the strict claim types of `Claims`, the leeway, no `iat` check,
	## R-TP7, R-TP3 rows 4 to 8, R-TP16, and each `detail` text of slice 108.

	## A token after `decode`: its signature is not checked yet. `header` and `registered` come from `Jwt.decode`. `kid` is the `kid` of the header
	## (`decode` refuses a token with no `kid`). `claims` are the claims of `Claims` (`Jwt.claims_as`). `signing_input` and `signature` are those of
	## `Jwt.Token`.
	Token : { kid : Str, header : Jwt.Header, registered : Jwt.Claims, claims : Oidc.Claims, signing_input : List(U8), signature : List(U8) }

	## The JWKS as the Worker keeps it (the value of the `Memo` of `worker/Auth.roc`): the JWKS text as read, and the time of the read.
	## `Auth.load!` keeps a text only when `Jwk.parse_set` accepts it. The `Memo` keeps the text, not a `List(Jwk.Key)`. A key list also round-trips in a
	## `--opt=speed` build; only a `--opt=dev` build fails, by roc-lang/roc#12782 (slice file 108b, section 9 P1).
	KeySet : { fetched_ms : U64, jwks : Str }

	## The `alg` allowlist of `Jwt.decode` (R-TP3 row 1): RS256 only.
	algs : List(Jwt.Alg)
	algs = [RS256]

	## R-TP3 row 1 before the key: `Jwt.decode` with `Jwt.Options.{ algs }` (the default `max_token_bytes`, 8192, Q108b-1), then the `kid`,
	## then `Jwt.claims_as` into `Claims`. Each fault is 401 `Unauthenticated`:
	## - an error of `Jwt.decode`: `jwt_problem(err, "")` (the `detail` texts of slice 108)
	## - the header has no `kid`: `the token kid is missing`
	## - `Jwt.claims_as` fails (a claim of `Claims` of the wrong JSON type, also `aud` as a list and an `exp` with a fraction): `the token is not a valid JWT`
	decode : Str -> Try(Oidc.Token, Problem)
	decode = |text| {
		token = Jwt.decode(text, Jwt.Options.{ algs }) ? |err| jwt_problem(err, "")
		kid = token.header.kid ? |Missing| Problem.new(Unauthenticated, "the token kid is missing")
		claims : Oidc.Claims
		claims = Jwt.claims_as(token) ? |_| not_jwt
		Ok({ kid, header: token.header, registered: token.claims, claims, signing_input: token.signing_input, signature: token.signature })
	}

	## The key step of R-TP3 row 1 and R-TP16, with `Jwk.select` in place of a `kid` compare. `age` is `now_ms - keys.fetched_ms`, or 0 when
	## `now_ms` is before the fetch time.
	## 1. `age > max_age_ms`: `Reload` (also when a key fits).
	## 2. `Jwk.select` over the keys of `Jwk.parse_set(keys.jwks)` gives a key: `Use(key)` (a text that does not parse has no key). A key with the `kid` of the token that does not fit RS256 (another `kty`,
	##    another `alg`, `use` not `sig`) is no key (`NoKey`).
	## 3. `NoKey` or `ManyKeys`, and `age > reread_after_ms`: `Reload`.
	## 4. Else `Refuse(unknown_kid(kid))`, with the `kid` of the header (or the empty text when it has none).
	key_for : Oidc.KeySet, Jwt.Header, U64 -> [Use(Jwk.Key), Reload, Refuse(Problem)]
	key_for = |keys, header, now_ms| {
		age = now_ms.minus_saturated(keys.fetched_ms)
		if age > max_age_ms {
			Reload
		} else {
			list = Jwk.parse_set(keys.jwks) ?? []
			match Jwk.select(list, header) {
				Ok(key) => Use(key)
				Err(_) => if (age > reread_after_ms) Reload else Refuse(unknown_kid(header.kid ?? ""))
			}
		}
	}

	## R-TP3 rows 1 (`iss`), 2 (`aud`) and 3 (`exp`, `nbf`) after the signature: `Jwt.check` with `now_ms`, `aud` `OneOf([audience])`,
	## `iss` `OneOf([issuer])`, `leeway_s` 60 and `require` `[Iss, Aud, Exp, Nbf]`. Talon checks no `iat` (R-TP3 row 3 names `exp` and `nbf` only),
	## so the claims go to `Jwt.check` with `iat` = `Err(Missing)`. An error is `jwt_problem(err, audience)`.
	check_registered : Jwt.Claims, { audience : Str, now_ms : U64 } -> Try({}, Problem)
	check_registered = |claims, ctx| {
		rules = Jwt.Rules.{ now_ms: ctx.now_ms, aud: OneOf([ctx.audience]), iss: OneOf([issuer]), leeway_s, require: [Iss, Aud, Exp, Nbf] }
		Jwt.check({ ..claims, iat: Err(Missing) }, rules).map_err(|err| jwt_problem(err, ctx.audience))
	}

	## The answer of each `Jwt.Error` (R-AP21, R-AP26, R-TP3). Each one is 401 `Unauthenticated`. `audience` is the setting `AUDIENCE`.
	## | Error | `detail` |
	## | --- | --- |
	## | `AlgMissing` | `the token alg is missing` |
	## | `AlgNone` | `the token alg is "none", expected "RS256"` |
	## | `AlgNotAllowed(alg)` | `the token alg is "<alg>", expected "RS256"` |
	## | `TooLong`, `NotCompact`, `BadBase64`, `BadUtf8`, `BadJson`, `CritUnsupported`, `EmptySignature`, `BadSignatureLength` | `the token is not a valid JWT` |
	## | `MissingClaim(claim)` | `token claim <claim> is missing` |
	## | `WrongIssuer(iss)` | `token claim iss is "<iss>", expected "https://token.actions.githubusercontent.com"` |
	## | `WrongAudience(values)` | `token claim aud is "<v1>", expected "<audience>"`; more values: each quoted, joined with `, ` |
	## | `WrongSubject(sub)` | `token claim sub is "<sub>"` |
	## | `Expired` | `token claim exp is <exp>: the token expired (now is <now>, leeway <leeway> s)` |
	## | `NotYetValid` | `token claim nbf is <nbf>: the token is not valid yet (now is <now>, leeway <leeway> s)` |
	## | `IssuedInFuture` | `token claim iat is <iat>: the token is issued in the future (now is <now>, leeway <leeway> s)` |
	## `<exp>`, `<nbf>`, `<iat>` are whole seconds, rounded down (`Dec.floor_to_i128`). `<now>` is `now_ms // 1000`.
	jwt_problem : Jwt.Error, Str -> Problem
	jwt_problem = |err, audience| Problem.new(Unauthenticated, jwt_detail(err, audience))

	## The `detail` of `jwt_problem`.
	jwt_detail : Jwt.Error, Str -> Str
	jwt_detail = |err, audience| match err {
		AlgMissing => "the token alg is missing"
		AlgNone => "the token alg is \"none\", expected \"RS256\""
		AlgNotAllowed(alg) => "the token alg is \"${alg}\", expected \"RS256\""
		TooLong(_) | NotCompact | BadBase64(_) | BadUtf8(_) | BadJson(_) | CritUnsupported(_) | EmptySignature | BadSignatureLength(_) => "the token is not a valid JWT"
		MissingClaim(claim) => "token claim ${Jwt.claim_to_str(claim)} is missing"
		WrongIssuer(iss) => "token claim iss is \"${iss}\", expected \"${issuer}\""
		WrongAudience(values) => "token claim aud is ${Str.join_with(values.map(|v| "\"${v}\""), ", ")}, expected \"${audience}\""
		WrongSubject(sub) => "token claim sub is \"${sub}\""
		Expired(e) => "token claim exp is ${seconds(e.exp)}: the token expired ${clock(e)}"
		NotYetValid(e) => "token claim nbf is ${seconds(e.nbf)}: the token is not valid yet ${clock(e)}"
		IssuedInFuture(e) => "token claim iat is ${seconds(e.iat)}: the token is issued in the future ${clock(e)}"
	}

	## A NumericDate in whole seconds, rounded down.
	seconds : Dec -> Str
	seconds = |value| value.floor_to_i128().to_str()

	## The text `(now is <now>, leeway <leeway> s)` of a time error.
	clock : { now_ms : U64, leeway_s : U64, .. } -> Str
	clock = |e| "(now is ${(e.now_ms // 1000).to_str()}, leeway ${e.leeway_s.to_str()} s)"

	## The claims that the Worker reads. A claim that is not in the token is `Err(Missing)`. A missing claim fails the row that checks it.
	## A claim of the wrong JSON type (for example a number for `repository_id`) makes the token not valid (`decode` gives 401).
	## `exp` and `nbf` are seconds since 1970 (RFC 7519 NumericDate, integers in GitHub tokens).
	## The last 6 claims and `workflow_ref`, `event_name` are the recorded claims of R-TP6 (slice 114 writes them). This slice does not check them,
	## except `workflow_ref` and `event_name` for R-TP7 and R-TP3 row 8.
	Claims : {
		iss : Try(Str, [Missing]),
		aud : Try(Str, [Missing]),
		exp : Try(U64, [Missing]),
		nbf : Try(U64, [Missing]),
		repository : Try(Str, [Missing]),
		repository_id : Try(Str, [Missing]),
		repository_owner_id : Try(Str, [Missing]),
		repository_visibility : Try(Str, [Missing]),
		ref : Try(Str, [Missing]),
		ref_type : Try(Str, [Missing]),
		event_name : Try(Str, [Missing]),
		workflow_ref : Try(Str, [Missing]),
		workflow_sha : Try(Str, [Missing]),
		job_workflow_ref : Try(Str, [Missing]),
		run_id : Try(Str, [Missing]),
		run_attempt : Try(Str, [Missing]),
		actor_id : Try(Str, [Missing]),
		runner_environment : Try(Str, [Missing]),
	}

	## The kept JWKS is read again when it is older than this (1 h, Q108-2).
	max_age_ms : U64
	max_age_ms = 3_600_000

	## An unknown `kid` reads the JWKS again only when the kept copy is older than this (60 s, Q108-1).
	reread_after_ms : U64
	reread_after_ms = 60_000

	## The issuer of GitHub Actions OIDC tokens (R-TP3 row 1).
	issuer : Str
	issuer = "https://token.actions.githubusercontent.com"

	## The JWKS of GitHub Actions (R-TP3 row 1, API.md RN6). The Worker reads it with no token.
	jwks_url : Str
	jwks_url = "https://token.actions.githubusercontent.com/.well-known/jwks"

	## The leeway of R-TP3 row 3, in seconds.
	leeway_s : U64
	leeway_s = 60

	## R-AP26: the `Authorization` header selects the path. `NoToken`: the request has no header (an ingest, or 401 on a route that needs a token).
	## `Token(text)`: the header is `Bearer <text>` with a text that is not empty and has no space. One space after `Bearer`.
	## The scheme is compared with no case (RFC 9110 11.1, Q108-5): `bearer`, `BEARER` and `Bearer` are accepted.
	## Any other value is `Refuse(401)` with the `detail` `the Authorization header must be "Bearer <token>"`: never an ingest (R-AP26).
	bearer : Try(Str, [NotFound]) -> [Token(Str), NoToken, Refuse(Problem)]
	bearer = |header| match header {
		Err(NotFound) => NoToken
		Ok(text) => match text.split_on(" ") {
			[scheme, token] if scheme.caseless_ascii_equals("bearer") and !token.is_empty() => Token(token)
			_ => Refuse(Problem.new(Unauthenticated, "the Authorization header must be \"Bearer <token>\""))
		}
	}

	## The 401 of a route that needs a token, when the request has none (R-AP21, R-AP6, R-AP10).
	## `detail`: `the request has no Authorization header: this route needs a GitHub OIDC token`.
	missing_token : Problem
	missing_token = Problem.new(Unauthenticated, "the request has no Authorization header: this route needs a GitHub OIDC token")

	not_jwt : Problem
	not_jwt = Problem.new(Unauthenticated, "the token is not a valid JWT")

	## The 401 of a token whose `kid` is not in the JWKS, also after the one read again (`worker/Auth.roc`).
	## `detail`: `the token kid "<kid>" is not in the GitHub JWKS`.
	unknown_kid : Str -> Problem
	unknown_kid = |kid| Problem.new(Unauthenticated, "the token kid \"${kid}\" is not in the GitHub JWKS")

	## The 502 of a JWKS read that fails (R-AP21 `upstream`: a read from GitHub failed): a status other than 200, no answer, or a body that `Jwk.parse_set` refuses.
	jwks_status : U16 -> Problem
	jwks_status = |status| Problem.new(Upstream, "the GitHub JWKS read failed with status ${status.to_str()}")

	jwks_no_answer : Problem
	jwks_no_answer = Problem.new(Upstream, "the GitHub JWKS read failed: no answer")

	jwks_bad : Problem
	jwks_bad = Problem.new(Upstream, "the GitHub JWKS is not a valid JWKS")

	## The 401 of a signature that `WebCrypto.verify!` refuses. `detail`: `the token signature is not valid`.
	bad_signature : Problem
	bad_signature = Problem.new(Unauthenticated, "the token signature is not valid")

	## The problem of a claim that the token does not have.
	missing : Problem.Kind, Str -> Problem
	missing = |kind, name| Problem.new(kind, "token claim ${name} is missing")

	## A claim that must be equal to `want` (an exact compare).
	claim_is : Problem.Kind, Str, Try(Str, [Missing]), Str -> Try({}, Problem)
	claim_is = |kind, name, claim, want| claim_in(kind, name, claim, [want], "\"${want}\"")

	## A claim that must be one of `wants`. `expected` is the text of `wants` in the `detail`.
	claim_in : Problem.Kind, Str, Try(Str, [Missing]), List(Str), Str -> Try({}, Problem)
	claim_in = |kind, name, claim, wants, expected| match claim {
		Err(Missing) => Err(missing(kind, name))
		Ok(value) => if (wants.contains(value)) Ok({}) else Err(Problem.new(kind, "token claim ${name} is \"${value}\", expected ${expected}"))
	}

	## R-TP7: a compat bot token, after `check_registered`. Each fault is 403 `Forbidden`. The order: `repository_id`, `workflow_ref`, `event_name`.
	## `repository_id` is equal to `BOT_REPOSITORY_ID`, `workflow_ref` is equal to `BOT_WORKFLOW_REF` (exact compares),
	## `event_name` is `schedule` or `workflow_dispatch`
	## (`detail`: `token claim event_name is "<value>", expected "schedule" or "workflow_dispatch"`).
	check_bot : Oidc.Claims, { repository_id : Str, workflow_ref : Str } -> Try({}, Problem)
	check_bot = |claims, bot| {
		claim_is(Forbidden, "repository_id", claims.repository_id, bot.repository_id)?
		claim_is(Forbidden, "workflow_ref", claims.workflow_ref, bot.workflow_ref)?
		claim_in(Forbidden, "event_name", claims.event_name, ["schedule", "workflow_dispatch"], "\"schedule\" or \"workflow_dispatch\"")
	}

	## R-TP3 rows 4, 6, 7 and 8 of a publish token, in this order, after `check_registered`. Each fault is 403 `Forbidden`.
	## The caller (slice 114) gives the parts of the asset URL: `host`, `owner_repo` (`owner/repo`) and `tag`.
	## Row 4: `host` is `github.com` (`detail`: `token claim repository: the asset URL host is "<host>", expected "github.com"`),
	## and `repository` is equal to `owner_repo`, ASCII case-insensitive.
	## Row 6: `repository_visibility` is `public`. Row 7: `ref_type` is `tag`, then `ref` is `refs/tags/<tag>` (exact compare).
	## Row 8: `event_name` is `release`, `push` or `workflow_dispatch`
	## (`detail`: `token claim event_name is "<value>", expected "release", "push" or "workflow_dispatch"`).
	## Row 5 is `binding_ok`: it needs the `repos` row (D1).
	check_publish : Oidc.Claims, { host : Str, owner_repo : Str, tag : Str } -> Try({}, Problem)
	check_publish = |claims, asset| {
		if asset.host != "github.com" {
			Err(Problem.new(Forbidden, "token claim repository: the asset URL host is \"${asset.host}\", expected \"github.com\""))
		} else {
			repository = claims.repository ? |Missing| missing(Forbidden, "repository")
			if !repository.caseless_ascii_equals(asset.owner_repo) {
				Err(Problem.new(Forbidden, "token claim repository is \"${repository}\", expected \"${asset.owner_repo}\""))
			} else {
				claim_is(Forbidden, "repository_visibility", claims.repository_visibility, "public")?
				claim_is(Forbidden, "ref_type", claims.ref_type, "tag")?
				claim_is(Forbidden, "ref", claims.ref, "refs/tags/${asset.tag}")?
				claim_in(Forbidden, "event_name", claims.event_name, ["release", "push", "workflow_dispatch"], "\"release\", \"push\" or \"workflow_dispatch\"")
			}
		}
	}

	## R-TP3 row 5: with no `repos` row, `Bool.True`. With a row, `Bool.True` when the claim `repository_id` or the claim `repository_owner_id`
	## is equal to the id of the row. A missing claim is equal to no id. The problem of a `Bool.False` is open (question Q108-3), so this
	## function gives no `Problem`: slices 113 and 114 map it.
	binding_ok : Oidc.Claims, Try({ repository_id : Str, repository_owner_id : Str }, [NoRow]) -> Bool
	binding_ok = |claims, row| match row {
		Err(NoRow) => Bool.True
		Ok(ids) => (claims.repository_id == Ok(ids.repository_id)) or (claims.repository_owner_id == Ok(ids.repository_owner_id))
	}
}
