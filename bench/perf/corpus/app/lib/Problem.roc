## The error answer of every route: RFC 9457 problem details (Registry 4.2, R-AP21).
## Pure. The answer has the media type `application/problem+json` (R-AP23): the handler sets it, not this module.
## The tests are in `worker/tests/unit/ProblemTest.roc`.
Problem :: { kind : Problem.Kind, detail : Str }.{

	is_eq : _

	## The 18 problem types of R-AP21, in the order of the table.
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
		# Slice 123d (R-AP82): 503 `/errors/busy`, title `Busy`.
		Busy,
	]

	new : Problem.Kind, Str -> Problem
	new = |kind, detail| { kind, detail }

	## The `type` member: a relative URI such as `/errors/not-found`.
	type_uri : Problem.Kind -> Str
	type_uri = |kind| "/errors/${kebab(kind)}"

	## The name of the type in the URI: the type name in words, lower case, with `-`.
	kebab : Problem.Kind -> Str
	kebab = |kind| match kind {
		BadRequest => "bad-request"
		Unauthenticated => "unauthenticated"
		Forbidden => "forbidden"
		RepositoryChanged => "repository-changed"
		NotFound => "not-found"
		MethodNotAllowed => "method-not-allowed"
		LabelConflict => "label-conflict"
		IdCollision => "id-collision"
		UnsupportedClient => "unsupported-client"
		TooLarge => "too-large"
		UnsupportedMediaType => "unsupported-media-type"
		NotACandidate => "not-a-candidate"
		SuccessorMismatch => "successor-mismatch"
		SweepIncomplete => "sweep-incomplete"
		RateLimited => "rate-limited"
		Internal => "internal"
		Upstream => "upstream"
		Busy => "busy"
	}

	## The HTTP status of the type (R-AP21 table).
	status : Problem.Kind -> U16
	status = |kind| match kind {
		BadRequest => 400
		Unauthenticated => 401
		Forbidden => 403
		RepositoryChanged => 403
		NotFound => 404
		MethodNotAllowed => 405
		LabelConflict => 409
		IdCollision => 409
		UnsupportedClient => 400
		TooLarge => 413
		UnsupportedMediaType => 415
		NotACandidate => 422
		SuccessorMismatch => 422
		SweepIncomplete => 422
		RateLimited => 429
		Internal => 500
		Upstream => 502
		Busy => 503
	}

	## The HTTP status of a problem: the status of its type.
	http_status : Problem -> U16
	http_status = |problem| status(problem.kind)

	## The `type` member of a problem (for a log line of a job that has no response, slice 118b).
	type_of : Problem -> Str
	type_of = |problem| type_uri(problem.kind)

	## The `detail` member of a problem.
	detail_of : Problem -> Str
	detail_of = |problem| problem.detail

	## The `title` member: a short text that depends only on the type (TW24 proposal, slice 101 section 4).
	title : Problem.Kind -> Str
	title = |kind| match kind {
		BadRequest => "Bad request"
		Unauthenticated => "Unauthenticated"
		Forbidden => "Forbidden"
		RepositoryChanged => "Repository changed"
		NotFound => "Not found"
		MethodNotAllowed => "Method not allowed"
		LabelConflict => "Label conflict"
		IdCollision => "Id collision"
		UnsupportedClient => "Unsupported client"
		TooLarge => "Too large"
		UnsupportedMediaType => "Unsupported media type"
		NotACandidate => "Not a candidate"
		SuccessorMismatch => "Successor mismatch"
		SweepIncomplete => "Sweep incomplete"
		RateLimited => "Rate limited"
		Internal => "Internal error"
		Upstream => "Upstream error"
		Busy => "Busy"
	}

	## The JSON text of the answer body: the members `type`, `title`, `status` and `detail`.
	## `detail` is escaped as JSON text (quotes, backslashes, control characters).
	to_json : Problem -> Str
	to_json = |problem| Json.to_str({
		type: type_uri(problem.kind),
		title: title(problem.kind),
		status: status(problem.kind),
		detail: problem.detail,
	})

	## R-AP46: the same body with the extra members `field` (the name of the query parameter or body field) and `limit` (the number that was passed).
	to_json_with : Problem, { field : Str, limit : U64 } -> Str
	to_json_with = |problem, extra| Json.to_str({
		type: type_uri(problem.kind),
		title: title(problem.kind),
		status: status(problem.kind),
		detail: problem.detail,
		field: extra.field,
		limit: extra.limit,
	})

	## The causes of a trap in the platform shim (API.md 10.3, R-AP82), as the fields of `on_trap`.
	Cause : [Crashed, Alarm, Cpu, Oom, Shed, Deadline, Cancelled, Event, Failed]

	## R-AP82: the problem of a cause. `Busy` (503) for oom, shed, cpu, deadline, alarm and cancelled; `Internal` (500) for crashed, event and failed.
	## The `detail` is fixed text: it never has the text of the crash (TR8). The platform shim adds `retry-after: 1` on oom and shed (TR7).
	for_cause : Problem.Cause -> Problem
	for_cause = |cause| match cause {
		Crashed | Event | Failed => Problem.new(Internal, "a fault in the Worker")
		Alarm | Cancelled => Problem.new(Busy, "the Worker stopped the request")
		Cpu => Problem.new(Busy, "the request used its CPU budget")
		Oom => Problem.new(Busy, "the Worker has no memory for this request")
		Shed => Problem.new(Busy, "the Worker is busy: send the request again")
		Deadline => Problem.new(Busy, "the request used its time budget")
	}
}
