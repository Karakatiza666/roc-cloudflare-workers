app [event!] {
	base58: "https://github.com/Karakatiza666/roc-base58/releases/download/0.1.0/BgUuQGqWY94NikfEx4rBkWkgxYhngMim3ZEnD8wpM4NS.tar.zst",
	header: "https://github.com/Karakatiza666/roc-app-header/releases/download/0.1.0/HDQnwrX2Bcm8Jsf8RMC9ZdbVGwPiqD2nCLP7Zf1osfgU.tar.zst",
	jwt: "https://github.com/Karakatiza666/roc-jwt/releases/download/0.0.1/C35APf1eow8zsCV6yrDpXLr3wxrMQVPdtoTQSGAM9dDh.tar.zst",
	lib: "lib/main.roc",
	pf: platform "../../../../platform/main.roc",
	records: "records/main.roc",
	roc: "nightly-2026-11-06-34f137a",
	semver: "https://github.com/Karakatiza666/roc-semver/releases/download/0.2.0/BzgH68Q1yBkg7F1ZpFsiEg73ZwkaBrFdcLpX2pUkay9i.tar.zst",
	tar: "https://github.com/Karakatiza666/roc-tar/releases/download/0.0.2/ynGk61syE32Lobjgwd3ZNRURf78xPGxr8Nzi1bSuhUr.tar.zst",
}

## The registry Worker (Registry 4 to 8). Slice 101 is the skeleton: the entry, the router, the problem form.
## Slice 101: `fetch!` is the router. `scheduled!` and `queue!` are stubs until slices 118 to 120 (docs/slices/101-worker-skeleton.md section 3.3).
import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Queue
import pf.Env
import lib.Client
import lib.Daily
import lib.Reconcile
import lib.Problem
import lib.Route
import Auth
import ReadRoutes
import ClosureRoute
import CompatRoutes
import CompatReadRoutes
import ShortRoutes
import ToolchainRoutes
import IngestRoutes
import PublishRoutes
import HintRoutes
import LoginRoutes
import GithubRead
import WebhookRoutes
import IndexQueue
import DailyCrons
import ReconcileCron

db = D1.binding("DB")

fetch! : Request => Try(Response, _)
fetch! = |req| {
	base = {
		method: req.method().to_str(),
		segments: req.segments(),
		content_type: req.header("content-type"),
		has_body: Bool.False,
	}
	match client_refusal!(base, req) {
		Refused(res) => Ok(res)
		Pass => {
			input = { ..base, has_body: body_present!(req) }
			match Route.decide(input) {
				Refuse(problem) => Ok(problem_response(problem))
				NotAllowed(problem, allow) => Ok(problem_response(problem).with_header("allow", Str.join_with(allow, ", ")))
				Handle(id) => handle!(id, req)
			}
		}
	}
}

## R-AP45, R-AP48 row 3: the check of the client version. It comes after the path (row 1) and the method (row 2) and before the size and the media type (rows 4, 5),
## so the route is asked once with no body: only `Handle(id)` (a route that serves the method) is checked. The settings `MIN_TLN` and `MIN_TLN_WRITE` are read
## only then; a setting that is not set is an empty text (not checked). `Refused(res)` is the 400 `unsupported-client`.
client_refusal! : Route.Input, Request => [Refused(Response), Pass]
client_refusal! = |base, req| match Route.decide(base) {
	Handle(id) => {
		min = Env.var!("MIN_TLN") ?? ""
		min_write = Env.var!("MIN_TLN_WRITE") ?? ""
		match Client.check({ user_agent: req.header("user-agent"), write: Client.is_write(id), min, min_write }) {
			Ok({}) => Pass
			Err(refusal) => Refused(Response.from_bytes(400, "application/problem+json", Client.refusal_json(refusal).to_utf8()))
		}
	}
	_ => Pass
}

## The most bytes that the Worker reads from a request body (R-AP46: 256 KB).
body_limit : U64
body_limit = 262144

## Is there a request body (R-AP23: a request with no body gets no media check)? The platform gives a body that is not `Empty` also for a request with
## no body, so the answer comes from the header `content-length` (0 is no body), and when the header is absent or not a number, from a read of
## at most `body_limit` bytes: 0 bytes is no body. A read that fails or is too large is a body (the route answers 413 or 400 later).
body_present! : Request => Bool
body_present! = |req| match req.header("content-length") {
	Ok(text) => match U64.from_str(text.trim()) {
		Ok(n) => n > 0
		Err(_) => read_present!(req)
	}
	Err(NotFound) => read_present!(req)
}

read_present! : Request => Bool
read_present! = |req| match req.body() {
	Empty => Bool.False
	_ => match req.bytes_with!({ max_bytes: body_limit }) {
		Ok(bytes) => !bytes.is_empty()
		Err(_) => Bool.True
	}
}

## The answer of a problem (R-AP21, R-AP23): the media type is exactly `application/problem+json`.
problem_response : Problem -> Response
problem_response = |problem| Response.from_bytes(problem.http_status(), "application/problem+json", problem.to_json().to_utf8())

## Run the handler of a route. Each `Err` of a handler is the problem `Internal` with a fixed `detail`: the answer shows no inner state (R-AP48).
handle! : Route.Id, Request => Try(Response, _)
handle! = |id, req| {
	match read_answer(run!(id, req)) {
		Ok(res) => Ok(res)
		Err(_) => Ok(problem_response(Problem.new(Internal, "the Worker failed to handle the request")))
	}
}

## Slice 117: the four account routes are `LoginRoutes` (login, tracker, delete; docs/slices/117-login.md).
## Slice 112: the ingest (R-AP9). A request with `Authorization` is a publish (R-AP26, slice 114: `PublishRoutes`).
## Slice 110: the closure route. `ClosureRoute` gives `Refuse(problem)` for a 400 and `Fault` for a fault of the Worker, as `ReadRoutes`.
## Slice 108: the toolchain route does the bot check (R-TP7). A failed check is its own problem. Slice 109: `ToolchainRoutes` does the rest (`GET` and `PUT`).
## Slice 106: the three read routes. `ReadRoutes` gives `Refuse(problem)` for a 400 or a 404 and `Fault` for a fault of the Worker (500 `internal`).
## `run!` gives the `ReadRoutes.Error` of the route. `handle!` calls `read_answer` once, so the code of `problem_response` is in one place (slice 227).
run! : Route.Id, Request => Try(Response, ReadRoutes.Error)
run! = |id, req| match id {
	GetRepoReleases(owner, repo) => ReadRoutes.repo_releases!(req, owner, repo)
	GetArtifact(hash) => ReadRoutes.artifact!(req, hash)
	GetReleases => ReadRoutes.releases!(req)
	GetPackages => ShortRoutes.list!(req)
	PostClosure => ClosureRoute.post!(req)
	PostCompat => CompatRoutes.post!(req)
	GetSweep(tag) => CompatReadRoutes.sweep!(req, tag)
	GetCompatHints => CompatReadRoutes.audit!(req)
	GetArtifactCompat(hash) => CompatReadRoutes.artifact_compat!(req, hash)
	GetToolchains => ToolchainRoutes.list!(req)
	PostRelease => match req.header("authorization") {
		Ok(_) => PublishRoutes.post!(req)
		Err(NotFound) => IngestRoutes.post!(req)
	}
	PostTokens => LoginRoutes.post_tokens!(req)
	DeleteTokens => LoginRoutes.delete_tokens!(req)
	GetMe => LoginRoutes.get_me!(req)
	DeleteMe => LoginRoutes.delete_me!(req)
	PostWebhook => WebhookRoutes.post!(req)
	PutToolchain(tag) => match Auth.bot!(req) {
		Err(problem) => Err(Refuse(problem))
		Ok(_) => ToolchainRoutes.put!(req, tag)
	}
}

read_answer : Try(Response, ReadRoutes.Error) -> Try(Response, [Fault(Str)])
read_answer = |result| match result {
	Ok(res) => Ok(res)
	Err(Refuse(problem)) => Ok(problem_response(problem))
	Err(Fault(text)) => Err(Fault(text))
}

scheduled! : Worker.Scheduled => Try({}, _)
scheduled! = |_s| crash "todo"

queue! : Queue.Batch => Try({}, _)
queue! = |b| IndexQueue.consume!(b)

## Slice 123d (R-AP82, Q440): the fixed answer of a trap. The shim sends a copy of it with no Roc code; it adds `retry-after: 1` on oom and shed (TR7).
trap_fixed : Problem.Cause -> Worker.Fixed
trap_fixed = |cause| {
	problem = Problem.for_cause(cause)
	{
		status: problem.http_status(),
		headers: [{ name: "content-type", value: "application/problem+json" }, { name: "cache-control", value: "no-store" }],
		body: problem.to_json().to_utf8(),
	}
}

## Slice 120: the daily job. Slice 119b: the reconcile cron (every 5 min).
worker = Worker.new({ fetch!: fetch!, scheduled!: scheduled!, crons: [Worker.cron(Daily.cron, DailyCrons.run!), Worker.cron(Reconcile.cron, ReconcileCron.run!)], queue!: queue!, on_trap: { default: trap_fixed(Failed), crashed: trap_fixed(Crashed), alarm: trap_fixed(Alarm), cpu: trap_fixed(Cpu), oom: trap_fixed(Oom), shed: trap_fixed(Shed), deadline: trap_fixed(Deadline), cancelled: trap_fixed(Cancelled), event: trap_fixed(Event), failed: trap_fixed(Failed) }, bindings: [db.declare(), HintRoutes.limiter.declare(), IngestRoutes.limiter.declare(), LoginRoutes.limiter.declare(), IndexQueue.index.declare()] })

event! = |e| worker.event!(e)
