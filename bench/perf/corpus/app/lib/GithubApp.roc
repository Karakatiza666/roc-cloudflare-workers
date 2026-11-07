## The pure part of the GitHub read token (Registry R-PU25 token part, R-CT12, R-WH14; Design Q170; slice 119a).
## No effect, no platform import. The effects (the settings, the sign, the token request, the `Memo`, the clock, the read) are in `worker/GithubRead.roc`.
## The tests are `worker/tests/unit/GithubAppTest.roc` (W0) and `worker/tests/cases/githubtoken/` (W2). The slice file is `docs/slices/119a-read-token.md`.
## The `detail` texts and the order of the headers are proposals for the human review (TW24): the slice file section 6.
## The doc comment of each function is the rule.
import Toolchains

GithubApp :: [].{

	## The `user-agent` of every GitHub read of the Worker (GitHub refuses a read with none). The value that slices 109, 112 and 116a send today: no change.
	user_agent : Str
	user_agent = "talon-registry"

	## The `accept` of an API read (the value that slices 109 and 112 send today for the API).
	accept : Str
	accept = "application/vnd.github+json"

	## R-PU25: the Worker keeps a token until 5 min before its end. A token with less than this time left is not used.
	keep_margin_ms : U64
	keep_margin_ms = 300_000

	## An installation token and the end of its life in ms since 1970 (the member `expires_at` of the answer of GitHub).
	Token : { token : Str, expires_ms : U64 }

	## Why the Worker has no token. `NoSetting(name)`: the setting or secret is not set. `BadSetting(name)`: it is set and cannot be used (the id is not digits, the key is not a PEM
	## of a PKCS#8 key). `SignFailed`: the sign of the JWT failed (WebCrypto refuses the key). `TokenStatus(s)`: the token request got the status `s` (401, 403, 404, 5xx, any not 201).
	## `TokenNoAnswer`: the token request got no answer. `TokenBad`: the answer is not a token.
	Failure : [NoSetting(Str), BadSetting(Str), SignFailed, TokenStatus(U16), TokenNoAnswer, TokenBad]

	## R-PU25: the signing input of the JWT of the App, `base64url(header) + "." + base64url(payload)`, with no padding. The header is exactly `{"alg":"RS256","typ":"JWT"}`.
	## The payload is exactly `{"iat":<s - 60>,"exp":<s + 540>,"iss":<app_id>}` (this member order, no white space, `iss` a JSON number), with `s` = `now_ms // 1000`.
	## It is the form of `research/github-app-check/check.sh`, which GitHub accepted. `app_id` is the text of the setting `GITHUB_APP_ID`: 1 or more digits, else `Err(BadAppId)`.
	jwt_input : { app_id : Str, now_ms : U64 } -> Try(Str, [BadAppId])
	jwt_input = |x| {
		if x.app_id.is_empty() or !(x.app_id.to_utf8().all(is_digit)) {
			return Err(BadAppId)
		}
		id = U64.from_str(x.app_id).map_err(|_| BadAppId)?
		s = x.now_ms // 1000
		iat = if (s < 60) 0 else s - 60
		payload = "{\"iat\":${iat.to_str()},\"exp\":${(s + 540).to_str()},\"iss\":${id.to_str()}}"
		Ok("${base64url("{\"alg\":\"RS256\",\"typ\":\"JWT\"}".to_utf8())}.${base64url(payload.to_utf8())}")
	}

	is_digit : U8 -> Bool
	is_digit = |b| b >= 48 and b <= 57

	## R-PU25: the JWT text: the signing input, a `.`, and the signature bytes as base64url with no padding (RFC 7515 2: the alphabet `A-Z a-z 0-9 - _`, no `=`).
	jwt_text : { input : Str, signature : List(U8) } -> Str
	jwt_text = |x| "${x.input}.${base64url(x.signature)}"

	## R-PU25: the URL of the token request, `https://api.github.com/app/installations/<installation_id>/access_tokens` (the method is POST, the body is empty).
	token_url : Str -> Str
	token_url = |installation_id| "https://api.github.com/app/installations/${installation_id}/access_tokens"

	## The members of the answer that the Worker reads. `expires_at` is read as text, then `Toolchains.parse_time`.
	RawToken : { token : Str, expires_at : Str }

	## R-PU25: the answer of GitHub to the token request: a JSON object with `token` (text) and `expires_at` (`YYYY-MM-DDTHH:MM:SSZ`, the form of `Toolchains.parse_time`).
	## Other members (`permissions`, `repository_selection`, ...) are ignored (R-AP44). A text that is not JSON, a missing member or a bad time is `Err(BadAnswer)`.
	parse_token : Str -> Try(GithubApp.Token, [BadAnswer])
	parse_token = |text| {
		raw : Try(GithubApp.RawToken, _)
		raw = Json.parse(text)
		match raw {
			Ok(r) => match Toolchains.parse_time(r.expires_at) {
				Ok(expires_ms) => Ok({ token: r.token, expires_ms })
				Err(BadTime) => Err(BadAnswer)
			}
			Err(_) => Err(BadAnswer)
		}
	}

	## R-PU25: is the token still in use at `now_ms`? Yes when it has more than `keep_margin_ms` left: `now_ms + keep_margin_ms < expires_ms`.
	## The exact edge (`now_ms + keep_margin_ms == expires_ms`) is not fixed by the design and no test checks it.
	usable : GithubApp.Token, U64 -> Bool
	usable = |token, now_ms| token.expires_ms > now_ms and token.expires_ms - now_ms > GithubApp.keep_margin_ms

	## Q2 (slice file section 7): the text of the secret `GITHUB_APP_KEY` as a PKCS#8 PEM (`-----BEGIN PRIVATE KEY-----`, base64 lines, `-----END PRIVATE KEY-----`) to the DER bytes
	## for `WebCrypto.Pkcs8`. Lines end with `\n` or `\r\n`. A PKCS#1 PEM (`-----BEGIN RSA PRIVATE KEY-----`, the form that GitHub gives) is `Err(Pkcs1)`. Any other text, or a
	## body that is not base64, is `Err(NotPem)`.
	pkcs8_of_pem : Str -> Try(List(U8), [NotPem, Pkcs1])
	pkcs8_of_pem = |pem| {
		lines = pem.replace_each("\r", "").trim().split_on("\n").map(|line| line.trim())
		match (lines.first(), lines.last()) {
			(Ok("-----BEGIN PRIVATE KEY-----"), Ok("-----END PRIVATE KEY-----")) if lines.len() >= 3 => {
				middle = lines.drop_first(1).drop_last(1)
				bytes = base64_decode(Str.join_with(middle, "")).map_err(|_| NotPem)?
				if (bytes.is_empty()) Err(NotPem) else Ok(bytes)
			}
			(Ok("-----BEGIN RSA PRIVATE KEY-----"), Ok("-----END RSA PRIVATE KEY-----")) if lines.len() >= 3 => Err(Pkcs1)
			_ => Err(NotPem)
		}
	}

	## Q3 (slice file section 7): does a read of this URL get the token? Only a URL that starts with `https://api.github.com/` (the REST API, where R-PU25 counts the 5000 an hour).
	## Not `https://raw.githubusercontent.com/...` (the `.roc-version` read), not `https://github.com/...` (the asset download), not `https://api.github.com.evil.example/`,
	## not `https://api.github.com@evil.example/`.
	uses_token : Str -> Bool
	uses_token = |url| url.starts_with("https://api.github.com/")

	## The headers of a GitHub read, in this order. A URL with `uses_token`: `user-agent`, `accept`, `authorization: Bearer <token>`. Another URL: `user-agent` only (as slice 112 sends for
	## `.roc-version` today), and the token is not in any header. `Bearer` is the form of `research/github-app-check/check.sh`.
	read_headers : { url : Str, token : Str } -> List((Str, Str))
	read_headers = |x| if GithubApp.uses_token(x.url) {
		[("user-agent", GithubApp.user_agent), ("accept", GithubApp.accept), ("authorization", "Bearer ${x.token}")]
	} else {
		[("user-agent", GithubApp.user_agent)]
	}

	## Q4 (slice file section 7): what a missing token does to a route. `Upstream(detail)`: the route answers 502 `upstream` with this `detail` (slices 109 and 112), and the tag list
	## of the hint path is `[]` (key 0, R-CT12). `Fault(text)`: the route answers 500 `internal` with the fixed `detail` of R-AP48, and the hint path is the same as for `Upstream`.
	failure_class : GithubApp.Failure -> [Upstream(Str), Fault(Str)]
	failure_class = |failure| match failure {
		NoSetting(n) => Fault("the setting ${n} is not set")
		BadSetting(n) => Fault("the setting ${n} is not valid")
		SignFailed => Fault("the JWT of the App cannot be signed")
		TokenStatus(s) => Upstream("the GitHub installation token request failed with status ${s.to_str()}")
		TokenNoAnswer => Upstream("the GitHub installation token request failed: no answer")
		TokenBad => Upstream("the GitHub installation token answer is not valid")
	}

	# ---- base64 (RFC 4648) ----

	url_alphabet : List(U8)
	url_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".to_utf8()

	## base64url with no padding.
	base64url : List(U8) -> Str
	base64url = |bytes| {
		chars = bytes.chunks_of(3).join_map(
			|chunk| {
				b0 = chunk.get(0) ?? 0
				b1 = chunk.get(1) ?? 0
				b2 = chunk.get(2) ?? 0
				n = b0.to_u64() * 65536 + b1.to_u64() * 256 + b2.to_u64()
				quad = [n // 262144, (n // 4096) % 64, (n // 64) % 64, n % 64].map(|i| url_alphabet.get(i) ?? 65)
				quad.take_first(chunk.len() + 1)
			},
		)
		Str.from_utf8(chars) ?? ""
	}

	## The value of a standard base64 character.
	base64_value : U8 -> Try(U64, [BadChar])
	base64_value = |c| if c >= 65 and c <= 90 {
		Ok((c - 65).to_u64())
	} else if c >= 97 and c <= 122 {
		Ok((c - 71).to_u64())
	} else if c >= 48 and c <= 57 {
		Ok((c + 4).to_u64())
	} else if c == 43 {
		Ok(62)
	} else if c == 47 {
		Ok(63)
	} else {
		Err(BadChar)
	}

	## Standard base64 with padding (or none). A length of 1 mod 4, a character outside the alphabet, or a `=` that is not at the end is an error.
	base64_decode : Str -> Try(List(U8), [BadBase64])
	base64_decode = |text| {
		raw = text.to_utf8()
		pad = if (raw.ends_with([61, 61])) 2 else if (raw.ends_with([61])) 1 else 0
		data = raw.drop_last(pad)
		if data.len() % 4 == 1 or (pad > 0 and raw.len() % 4 != 0) {
			return Err(BadBase64)
		}
		values = data.map_try(base64_value).map_err(|_| BadBase64)?
		out = values.chunks_of(4).join_map(
			|group| {
				v = |i| group.get(i) ?? 0
				n = v(0) * 262144 + v(1) * 4096 + v(2) * 64 + v(3)
				triple = [(n // 65536).to_u8_wrap(), ((n // 256) % 256).to_u8_wrap(), (n % 256).to_u8_wrap()]
				triple.take_first(group.len() - 1)
			},
		)
		Ok(out)
	}
}
