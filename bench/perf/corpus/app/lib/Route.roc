## The route decision of the Worker (R-WH1, Registry 4.2). Pure: it reads no request and does no effect.
## The handler code reads the request, builds a `Route.Input`, and acts on the `Route.Decision`.
## The tests are in `worker/tests/unit/RouteTest.roc`.
import Problem

Route :: [].{

	## The routes that the Worker has. Each later slice adds its routes. Slice 101 has one: `POST /v1/closure` (R-AP3),
	## a stub whose handler gives `Err` (slice 101 section 3). Slice 106: `GET /v1/packages/{owner}/{repo}/releases` (R-AP1), `GET /v1/artifacts/{hash}` (R-AP2), `GET /v1/releases` (R-AP13, R-AP14). Slice 108: `PUT /v1/toolchains/{tag}` (R-AP6), the bot check only until slice 109. Slice 109: `GET /v1/toolchains` (R-AP5), `GetToolchains`; its line is in `decide` (`decide_get`). Slice 107: `GET /v1/packages` (R-AP7), `GetPackages`. Slice 115a: `POST /v1/compat` (R-AP10), `PostCompat`. Slice 115b: `GET /v1/sweeps/{tag}` (R-AP39), `GetSweep`; `GET /v1/compat_hints` (R-AP40), `GetCompatHints`; `GET /v1/artifacts/{hash}/compat` (R-AP4), `GetArtifactCompat`. Their lines in `decide` are missing until the code of the slices 115a and 115b. Slice 112: `POST /v1/releases` with no token (R-AP9), `PostRelease`. Its line in `decide` is for the code agent: `/v1/releases` serves `GET` (`GetReleases`) and `POST` (`PostRelease`, with the media check of a JSON body as `decide_closure`), and another method is 405 with `Allow: GET, POST`.
	## Slice 117 (login): `POST /v1/tokens` (R-AP37, `PostTokens`) and `DELETE /v1/tokens` (R-AP38, `DeleteTokens`), `GET /v1/contributors/me` (R-AP35, `GetMe`) and `DELETE /v1/contributors/me` (R-AP36, `DeleteMe`). Their lines in `decide` are for the code agent (docs/slices/117-login.md section 3.5): `/v1/tokens` serves `POST` (the media check of `decide_post`) and `DELETE` (no body check), another method is 405 with `Allow: DELETE, POST`; `/v1/contributors/me` serves `GET` and `DELETE` (no body check), another method is 405 with `Allow: DELETE, GET`.
	## Slice 118: `POST /v1/webhooks/github` (R-AP12), `PostWebhook`. Its line in `decide` is for the code agent (docs/slices/118-webhook.md section 3.2): `/v1/webhooks/github` serves `POST` (the media check of `decide_post`), another method is 405 with `Allow: POST`.
	Id : [PostClosure, PutToolchain(Str), GetToolchains, GetRepoReleases(Str, Str), GetArtifact(Str), GetReleases, GetPackages, PostCompat, GetSweep(Str), GetCompatHints, GetArtifactCompat(Str), PostRelease, PostTokens, DeleteTokens, GetMe, DeleteMe, PostWebhook]

	## What the decision needs from the request.
	## `method`: the text of the method (`GET`, `POST`, ..., or any other text). `segments`: the path split at `/`, with no empty item
	## (`Request.segments`). `content_type`: the value of the `Content-Type` header, if it has one. `has_body`: the body is not empty.
	Input : { method : Str, segments : List(Str), content_type : Try(Str, [NotFound]), has_body : Bool }

	## `Handle(id)`: call the handler of `id`. `Refuse(problem)`: answer with this problem and call no handler.
	## `NotAllowed(problem, allow)`: the same, and the answer has the header `Allow` with the methods `allow` of the path, joined with `, ` (R-AP21, RFC 9110 15.5.6).
	Decision : [Handle(Route.Id), Refuse(Problem), NotAllowed(Problem, List(Str))]

	## The order of the checks is R-AP48. This function does the rows 1, 2 and 5. The first check that fails gives the answer.
	## 1. The path is no route: `Refuse(NotFound)`, for each method and with any body (R-AP21). The method text is case sensitive, as in HTTP.
	## 2. The path is a route, and the method is not served on it: `NotAllowed(MethodNotAllowed, allow)` with the methods of the path.
	##    Slice 101: `/v1/closure` serves `POST`, so `allow` is `["POST"]`.
	## 3. A route that takes a JSON body, with a body, and no `Content-Type` or a media type that is not accepted: `Refuse(UnsupportedMediaType)` (R-AP23).
	##    Accepted: `application/json` with no parameter, or with the parameter `charset=utf-8`. The media type, the parameter name and the charset
	##    are compared with no case, and spaces around `;` are allowed (`Application/JSON; Charset=UTF-8` is accepted).
	##    Another charset, or `application/jsonx`, or another type, is refused. A request without a body is not checked.
	## 4. Else `Handle(id)`.
	decide : Route.Input -> Route.Decision
	decide = |input| {
		path = "/${Str.join_with(input.segments, "/")}"
		match input.segments {
			["v1", "closure"] => decide_closure(input, path)
			["v1", "toolchains"] => decide_get(input, path, GetToolchains)
			["v1", "toolchains", tag] => decide_toolchain(input, path, tag)
			["v1", "packages", owner, repo, "releases"] => decide_get(input, path, GetRepoReleases(owner, repo))
			["v1", "artifacts", hash] => decide_get(input, path, GetArtifact(hash))
			["v1", "releases"] => decide_releases(input, path)
			["v1", "tokens"] => decide_tokens(input, path)
			["v1", "contributors", "me"] => decide_me(input, path)
			["v1", "packages"] => decide_get(input, path, GetPackages)
			["v1", "compat"] => decide_post(input, path, PostCompat)
			["v1", "webhooks", "github"] => decide_post(input, path, PostWebhook)
			["v1", "sweeps", tag] => decide_get(input, path, GetSweep(tag))
			["v1", "compat_hints"] => decide_get(input, path, GetCompatHints)
			["v1", "artifacts", hash, "compat"] => decide_get(input, path, GetArtifactCompat(hash))
			_ => Refuse(Problem.new(NotFound, "no route for ${input.method} ${path}"))
		}
	}

	## `POST /v1/closure`: the method, then the media type of a body (R-AP48 rows 2 and 5).
	decide_closure : Route.Input, Str -> Route.Decision
	decide_closure = |input, path| {
		if input.method != "POST" {
			NotAllowed(Problem.new(MethodNotAllowed, "${input.method} is not allowed on ${path}"), ["POST"])
		} else if !input.has_body {
			Handle(PostClosure)
		} else {
			match input.content_type {
				Err(NotFound) => Refuse(Problem.new(UnsupportedMediaType, "the request body must be application/json, but the request has no Content-Type"))
				Ok(ct) => if (is_json_media(ct)) Handle(PostClosure) else Refuse(Problem.new(UnsupportedMediaType, "the request body must be application/json, got ${ct}"))
			}
		}
	}

	## A route that takes a JSON body with `POST` only (slice 115a): as `decide_closure`, for the route `id`.
	decide_post : Route.Input, Str, Route.Id -> Route.Decision
	decide_post = |input, path, id| {
		if input.method != "POST" {
			NotAllowed(Problem.new(MethodNotAllowed, "${input.method} is not allowed on ${path}"), ["POST"])
		} else if !input.has_body {
			Handle(id)
		} else {
			match input.content_type {
				Err(NotFound) => Refuse(Problem.new(UnsupportedMediaType, "the request body must be application/json, but the request has no Content-Type"))
				Ok(ct) => if (is_json_media(ct)) Handle(id) else Refuse(Problem.new(UnsupportedMediaType, "the request body must be application/json, got ${ct}"))
			}
		}
	}

	## `/v1/releases` (slice 112): `GET` is R-AP13, `POST` is the ingest (R-AP9, R-AP26) with the media check of `decide_post`. Another method: 405 with `Allow: GET, POST`.
	decide_releases : Route.Input, Str -> Route.Decision
	decide_releases = |input, path| match input.method {
		"GET" => Handle(GetReleases)
		"POST" => decide_post(input, path, PostRelease)
		_ => NotAllowed(Problem.new(MethodNotAllowed, "${input.method} is not allowed on ${path}"), ["GET", "POST"])
	}

	## `/v1/tokens` (slice 117): `POST` is the login (R-AP37) with the media check of `decide_post`, `DELETE` is the revoke (R-AP38, no body check). Another method: 405 with `Allow: DELETE, POST`.
	decide_tokens : Route.Input, Str -> Route.Decision
	decide_tokens = |input, path| match input.method {
		"POST" => decide_post(input, path, PostTokens)
		"DELETE" => Handle(DeleteTokens)
		_ => NotAllowed(Problem.new(MethodNotAllowed, "${input.method} is not allowed on ${path}"), ["DELETE", "POST"])
	}

	## `/v1/contributors/me` (slice 117): `GET` is the tracker (R-AP35), `DELETE` is the delete (R-AP36, no body check). Another method: 405 with `Allow: DELETE, GET`.
	decide_me : Route.Input, Str -> Route.Decision
	decide_me = |input, path| match input.method {
		"GET" => Handle(GetMe)
		"DELETE" => Handle(DeleteMe)
		_ => NotAllowed(Problem.new(MethodNotAllowed, "${input.method} is not allowed on ${path}"), ["DELETE", "GET"])
	}

	## `PUT /v1/toolchains/{tag}`: the method only. R-AP6 has no body, so no media check.
	decide_toolchain : Route.Input, Str, Str -> Route.Decision
	decide_toolchain = |input, path, tag| {
		if input.method == "PUT" {
			Handle(PutToolchain(tag))
		} else {
			NotAllowed(Problem.new(MethodNotAllowed, "${input.method} is not allowed on ${path}"), ["PUT"])
		}
	}

	## The read routes (slice 106): `GET` only, no body check (a `GET` has no body). Another method: 405 with `Allow: GET` (R-AP48 row 2).
	decide_get : Route.Input, Str, Route.Id -> Route.Decision
	decide_get = |input, path, id| {
		if input.method == "GET" {
			Handle(id)
		} else {
			NotAllowed(Problem.new(MethodNotAllowed, "${input.method} is not allowed on ${path}"), ["GET"])
		}
	}

	## R-AP23: `application/json`, no case. A `charset` parameter must be `utf-8`, as a token or a quoted string (RFC 9110, 8.3.1). Other parameters are ignored (R-AP44).
	## Spaces around `;` are allowed.
	is_json_media : Str -> Bool
	is_json_media = |ct| match split_params(ct) {
		[kind, .. as params] => is_json_type(kind) and params.all(param_ok)
		[] => Bool.False
	}

	is_json_type : Str -> Bool
	is_json_type = |kind| kind.trim().caseless_ascii_equals("application/json")

	## Split at `;`, but not at a `;` inside a quoted string: a piece with an odd number of quotes joins the next piece.
	split_params : Str -> List(Str)
	split_params = |ct| {
		var $parts = []
		var $open = ""
		var $joining = Bool.False
		for piece in ct.split_on(";") {
			text = if ($joining) "${$open};${piece}" else piece
			if quotes_odd(text) {
				$open = text
				$joining = Bool.True
			} else {
				$parts = $parts.append(text)
				$joining = Bool.False
			}
		}
		if ($joining) $parts.append($open) else $parts
	}

	quotes_odd : Str -> Bool
	quotes_odd = |text| text.split_on("\"").len() % 2 == 0

	## A `charset` parameter is good when its value is `utf-8`. Another parameter is good.
	param_ok : Str -> Bool
	param_ok = |param| match param.split_on("=") {
		[name, .. as rest] if name.trim().caseless_ascii_equals("charset") => is_utf8(Str.join_with(rest, "="))
		_ => Bool.True
	}

	## The value, without the quotes of a quoted string, is `utf-8`.
	is_utf8 : Str -> Bool
	is_utf8 = |value| {
		v = value.trim()
		bare = if (v.starts_with("\"") and v.ends_with("\"") and v.count_utf8_bytes() >= 2) v.drop_prefix("\"").drop_suffix("\"") else v
		bare.caseless_ascii_equals("utf-8")
	}
}
