## The handler of the GitHub webhook `POST /v1/webhooks/github` (Registry 4: R-AP12, R-AP46, R-AP79; 7: R-PU3, R-PU11; 8: R-WH14 `GITHUB_WEBHOOK_SECRET`; slice 118). The decisions are in `lib/Webhook.roc`
## (pure, W0). The tests are W2: `worker/tests/cases/webhook/`. `Err(Refuse(problem))` is a problem answer, `Err(Fault(text))` is 500 `internal` (R-AP48, never a `crash`). The body is a stub.
import pf.Request
import pf.Response
import pf.Env
import pf.WebCrypto
import lib.Problem
import lib.Webhook
import IndexQueue
import ReadRoutes

WebhookRoutes :: [].{

	## `POST /v1/webhooks/github` (R-AP12). `Route.decide` has done the path, the method and the media type (R-AP79 rows 1, 3). No D1 call, no GitHub call. The first check that fails gives the answer, in the order of R-AP79:
	## 1. `req.bytes_with!({ max_bytes: 1048576 })` (R-AP46, R-AP79 row 2, Design Q326: 1 MiB for this route; 1048576 bytes pass). `Err(TooLarge)`: 413 `too-large` with `field` `body` and `limit` 1048576 (as `IngestRoutes.too_large`). Another `Err`: the bytes `[]`.
	## 2. The secret `Env.secret!("GITHUB_WEBHOOK_SECRET")` (R-AP79 row 4, Design Q327). A missing secret, or an empty text, is `Err(Fault(..))` (500): it never means an empty key. It comes after steps 1 and the media type, and before the signature header, so a request with no signature header gets 500 when the secret is missing.
	## 3. The signature (R-AP79 row 5), then the event and the body (rows 6 to 9, Design Q320: the signature first). The signature: the header `x-hub-signature-256` is `Webhook.parse_signature` (`Err(Malformed)` and a missing header are
	##    `Webhook.bad_signature`, 401). The expected value is `WebCrypto.hmac_sha256(secret bytes, the RAW body bytes)`: the bytes as received, never a text that was parsed and written again. The compare is
	##    `WebCrypto.timing_safe_equal!(expected, given)` (constant time): one call for a header of the good form. A bad value is `Webhook.bad_signature`. The parse: `Webhook.parse_event({ event: header
	##    x-github-event ("" when it is missing), body })`; `Err(problem)` is the 400 (a missing or empty `x-github-event` header is 400, Design Q321).
	## 4. `Ignore`: the answer 202 and no send. `Send(message)`: `IndexQueue.index.send!(message)` (no `delay_ms`), then the answer 202. `Err(Infra(..))` of the send is `Err(Fault(..))`: GitHub shows a failed delivery.
	## 5. The answer: status 202, no body, `cache-control: no-store` (R-AP12), no `content-type`.
	post! : Request => Try(Response, ReadRoutes.Error)
	post! = |req| {
		bytes = match req.bytes_with!({ max_bytes: body_limit }) {
			Ok(b) => b
			Err(TooLarge) => return Ok(too_large)
			Err(BodyErr(_)) => []
		}
		secret = secret!()?
		check_signature!(req, secret, bytes)?
		decision = Webhook.parse_event({ event: req.header("x-github-event") ?? "", body: bytes }).map_err(|p| Refuse(p))?
		match decision {
			Ignore => {}
			Send(message) => IndexQueue.index.send!(message).map_err(|e| Fault(Str.inspect(e)))?
		}
		Ok(Response.from_status(202).with_header("cache-control", "no-store"))
	}

	## R-AP46, Q326: the most bytes of the body of this route (1 MiB).
	body_limit : U64
	body_limit = 1048576

	too_large : Response
	too_large = {
		problem = Problem.new(TooLarge, "the body of the webhook request is larger than its limit of ${body_limit.to_str()}")
		Response.from_bytes(413, "application/problem+json", Problem.to_json_with(problem, { field: "body", limit: body_limit }).to_utf8())
	}

	## R-WH14, Q327: a missing secret, or an empty one, is a fault. It is never the empty key.
	secret! : () => Try(List(U8), ReadRoutes.Error)
	secret! = || match Env.secret!("GITHUB_WEBHOOK_SECRET") {
		Ok(s) if !s.reveal().is_empty() => Ok(s.reveal().to_utf8())
		_ => Err(Fault("the secret GITHUB_WEBHOOK_SECRET is not set"))
	}

	## R-AP12: HMAC-SHA256 of the raw bytes, a constant time compare. A header that is missing or has a bad form needs no compare.
	check_signature! : Request, List(U8), List(U8) => Try({}, ReadRoutes.Error)
	check_signature! = |req, secret, bytes| {
		header = req.header("x-hub-signature-256").map_err(|_| Refuse(Webhook.bad_signature))?
		given = Webhook.parse_signature(header).map_err(|_| Refuse(Webhook.bad_signature))?
		if WebCrypto.timing_safe_equal!(WebCrypto.hmac_sha256(secret, bytes), given) {
			Ok({})
		} else {
			Err(Refuse(Webhook.bad_signature))
		}
	}
}
