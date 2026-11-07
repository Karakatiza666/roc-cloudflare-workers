## The one function for a GitHub read of the Worker (Registry R-PU25 token part, R-CT12; Design Q170; slice 119a). Slices 109 (`ToolchainRoutes`), 112 (`IngestRoutes`) and
## 116a (`HintRoutes`) call `GithubRead.send!` in place of `Http.send!`. The pure parts are `worker/lib/GithubApp.roc`. The flow is the slice file section 3.3.
import pf.Request
import pf.Response
import pf.Http
import pf.Env
import pf.Memo
import pf.Time
import pf.WebCrypto
import lib.GithubApp

GithubRead :: [].{

	## Add the headers of `GithubApp.read_headers` to the request (the token only when `GithubApp.uses_token`), send it, and give the response. The status of the response is not
	## checked here: the caller checks it as it does today. `NoAnswer` is a fault of the read itself (the same as the `Http.send!` error that the callers map today).
	## `Token(failure)` is why the Worker has no token (`GithubApp.Failure`); no read was sent.
	send! : Request => Try(Response, [NoAnswer, Token(GithubApp.Failure)])
	send! = |request| {
		url = request.url()
		token = if (GithubApp.uses_token(url)) current_token!().map_err(|f| Token(f))? else ""
		headers = GithubApp.read_headers({ url, token })
		Http.send!(headers.fold(request, |r, (name, value)| r.with_header(name, value))).map_err(|_| NoAnswer)
	}

	## The installation token, kept across requests in the isolate. The 5 min rule of R-PU25 is checked here on the clock of `Time.now_ms!`: the age rule of the `Memo` is on the
	## shim clock, so `max_age_ms` is only the life of a token.
	cache : Memo(GithubApp.Token)
	cache = Memo.new("github-read-token", { max_age_ms: 3_600_000 })

	current_token! : () => Try(Str, GithubApp.Failure)
	current_token! = || {
		held = cache.get!(load!)?
		if GithubApp.usable(held, Time.now_ms!()) {
			Ok(held.token)
		} else {
			cache.clear!()
			Ok(cache.get!(load!)?.token)
		}
	}

	## R-PU25 steps (a) to (d): the settings, the key, the signed JWT, the token request. A failure keeps nothing (the `Memo` keeps only an `Ok`).
	load! : () => Try(GithubApp.Token, GithubApp.Failure)
	load! = || {
		app_id = Env.var!("GITHUB_APP_ID").map_err(|_| NoSetting("GITHUB_APP_ID"))?
		installation = Env.var!("GITHUB_APP_INSTALLATION_ID").map_err(|_| NoSetting("GITHUB_APP_INSTALLATION_ID"))?
		secret = Env.secret!("GITHUB_APP_KEY").map_err(|_| NoSetting("GITHUB_APP_KEY"))?
		der = GithubApp.pkcs8_of_pem(secret.reveal()).map_err(|_| BadSetting("GITHUB_APP_KEY"))?
		input = GithubApp.jwt_input({ app_id, now_ms: Time.now_ms!() }).map_err(|_| BadSetting("GITHUB_APP_ID"))?
		signature = WebCrypto.sign!({ alg: RsaPkcs1(Sha256), key: Pkcs8(der), data: input.to_utf8() }).map_err(|_| SignFailed)?
		jwt = GithubApp.jwt_text({ input, signature })
		ask!(GithubApp.token_url(installation), jwt)
	}

	## The token request: a `POST` with an empty body.
	ask! : Str, Str => Try(GithubApp.Token, GithubApp.Failure)
	ask! = |url, jwt| {
		request = Request.post(url, Empty).with_header("user-agent", GithubApp.user_agent).with_header("accept", GithubApp.accept).with_header("authorization", "Bearer ${jwt}")
		res = Http.send!(request).map_err(|_| TokenNoAnswer)?
		if res.status() != 201 {
			return Err(TokenStatus(res.status()))
		}
		text = res.text!().map_err(|_| TokenBad)?
		GithubApp.parse_token(text).map_err(|_| TokenBad)
	}
}
