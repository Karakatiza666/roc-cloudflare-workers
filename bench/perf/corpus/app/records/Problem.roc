## The problem details of an error answer (Registry 4.2, R-AP21). The client reads them, and the Worker can write them. Pure.
## `worker/lib/Problem.roc` (slice 101) holds its own copy for now. A later slice moves the Worker to this module.
Problem :: [].{

	## The 18 types of R-AP21, in the order of the table. `Busy` (`/errors/busy`, 503) is the answer of a trap or a shed request (R-AP82, Design Q440, slice 104j).
	Kind : [
		BadRequest,
		Unauthenticated,
		Forbidden,
		RepositoryChanged,
		NotFound,
		MethodNotAllowed,
		LabelConflict,
		IdCollision,
		UnsupportedClient,
		TooLarge,
		UnsupportedMediaType,
		NotACandidate,
		SuccessorMismatch,
		SweepIncomplete,
		RateLimited,
		Internal,
		Upstream,
		Busy,
	]

	## The members of R-AP21 that only some types have: `issues_url` (repository-changed, R-TP12), `minimum` (unsupported-client, R-AP45), `field` and `limit` (too-large, R-AP46).
	Extra : [None, IssuesUrl(Str), Minimum(Str), Limit({ field : Str, limit : U64 })]

	## The body of an error answer: `type_text` (the `type` as read, also a type that is not in the table: R-AP52), `title`, `status`, `detail`, and the extra member. `kind_from_uri(type_text)` gives the kind.
	Body : { type_text : Str, title : Str, status : U16, detail : Str, extra : Problem.Extra }

	## `/errors/<kebab name>` (R-AP21).
	type_uri : Problem.Kind -> Str
	type_uri = |k| row(k).1

	## The table of R-AP21: kind, type, status.
	row : Problem.Kind -> (Problem.Kind, Str, U16)
	row = |k| match k {
		BadRequest => (k, "/errors/bad-request", 400)
		Unauthenticated => (k, "/errors/unauthenticated", 401)
		Forbidden => (k, "/errors/forbidden", 403)
		RepositoryChanged => (k, "/errors/repository-changed", 403)
		NotFound => (k, "/errors/not-found", 404)
		MethodNotAllowed => (k, "/errors/method-not-allowed", 405)
		LabelConflict => (k, "/errors/label-conflict", 409)
		IdCollision => (k, "/errors/id-collision", 409)
		UnsupportedClient => (k, "/errors/unsupported-client", 400)
		TooLarge => (k, "/errors/too-large", 413)
		UnsupportedMediaType => (k, "/errors/unsupported-media-type", 415)
		NotACandidate => (k, "/errors/not-a-candidate", 422)
		SuccessorMismatch => (k, "/errors/successor-mismatch", 422)
		SweepIncomplete => (k, "/errors/sweep-incomplete", 422)
		RateLimited => (k, "/errors/rate-limited", 429)
		Internal => (k, "/errors/internal", 500)
		Upstream => (k, "/errors/upstream", 502)
		Busy => (k, "/errors/busy", 503)
	}

	## The kind of a `type` value. An unknown `type` is `Err(UnknownType)`: a client must not crash on a type of a later registry.
	kind_from_uri : Str -> Try(Problem.Kind, [UnknownType])
	kind_from_uri = |u| {
		kinds : List(Problem.Kind)
		kinds = [BadRequest, Unauthenticated, Forbidden, RepositoryChanged, NotFound, MethodNotAllowed, LabelConflict, IdCollision, UnsupportedClient, TooLarge, UnsupportedMediaType, NotACandidate, SuccessorMismatch, SweepIncomplete, RateLimited, Internal, Upstream, Busy]
		kinds.find_first(|k| type_uri(k) == u).map_err(|_| UnknownType)
	}

	## The status of the table of R-AP21.
	status : Problem.Kind -> U16
	status = |k| row(k).2

	## A body with no `type`, no `status` or that is not JSON is `BadJson` (R-AP52). An unknown `type` is kept.
	## The wire form: the members that only some types have are left out when absent.
	Wire : {
		type : Str,
		title : Try(Str, [Missing]),
		status : U16,
		detail : Try(Str, [Missing]),
		issues_url : Try(Str, [Missing]),
		minimum : Try(Str, [Missing]),
		field : Try(Str, [Missing]),
		limit : Try(U64, [Missing]),
	}

	## R-AP74 row 2: `type` and `status` are read strict. Each optional member is read apart: a member that is `null` or has a wrong type is missing.
	Head : { type : Str, status : U16 }
	TitleOnly : { title : Try(Str, [Missing]) }
	DetailOnly : { detail : Try(Str, [Missing]) }
	UrlOnly : { issues_url : Try(Str, [Missing]) }
	MinimumOnly : { minimum : Try(Str, [Missing]) }
	FieldOnly : { field : Try(Str, [Missing]) }
	LimitOnly : { limit : Try(U64, [Missing]) }

	decode : Str -> Try(Problem.Body, [BadJson(Str)])
	decode = |text| {
		head : Try(Problem.Head, _)
		head = Json.parse(text)
		match head {
			Err(e) => Err(BadJson(Str.inspect(e)))
			Ok(h) => {
				title : Try(Problem.TitleOnly, _)
				title = Json.parse(text)
				detail : Try(Problem.DetailOnly, _)
				detail = Json.parse(text)
				url : Try(Problem.UrlOnly, _)
				url = Json.parse(text)
				minimum : Try(Problem.MinimumOnly, _)
				minimum = Json.parse(text)
				field : Try(Problem.FieldOnly, _)
				field = Json.parse(text)
				limit : Try(Problem.LimitOnly, _)
				limit = Json.parse(text)
				extra = match (url, minimum, field, limit) {
					(Ok({ issues_url: Ok(u) }), _, _, _) => IssuesUrl(u)
					(_, Ok({ minimum: Ok(m) }), _, _) => Minimum(m)
					(_, _, Ok({ field: Ok(f) }), Ok({ limit: Ok(l) })) => Limit({ field: f, limit: l })
					_ => None
				}
				Ok({
					type_text: h.type,
					title: title.map_ok(|w| w.title ?? "") ?? "",
					status: h.status,
					detail: detail.map_ok(|w| w.detail ?? "") ?? "",
					extra,
				})
			}
		}
	}

	encode : Problem.Body -> Str
	encode = |body| {
		base : Problem.Wire
		base = { type: body.type_text, title: Ok(body.title), status: body.status, detail: Ok(body.detail), issues_url: Err(Missing), minimum: Err(Missing), field: Err(Missing), limit: Err(Missing) }
		Json.to_str(
			match body.extra {
				None => base
				IssuesUrl(url) => { ..base, issues_url: Ok(url) }
				Minimum(min) => { ..base, minimum: Ok(min) }
				Limit({ field, limit }) => { ..base, field: Ok(field), limit: Ok(limit) }
			},
		)
	}
}
