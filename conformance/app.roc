app [event!] {
	http: "https://github.com/roc-lang/http/releases/download/2.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	pf: platform "../bench/platform/main.roc",
}

## The conformance app (PLAN.md 8c): one route for each function of a module and for its `Io` twin. `run.mjs` runs it
## in Miniflare and checks each answer. A route is `/<module>/<function>`. Each module has its routes in its own file
## (`<Module>Routes.roc`, a function `route!`) and one line below. README.md says how to add a module.
import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Kv
import pf.Object
import pf.Log
import HttpRoutes
import EnvRoutes
import TimeRoutes
import LogRoutes
import RateLimitRoutes
import CfRoutes
import ShimRoutes
import WebCryptoRoutes
import R2Routes
import CacheRoutes
import D1Routes
import MemoRoutes
import PinRoutes
import QueueRoutes
import KvRoutes
import EmailRoutes
import TailRoutes
import AiRoutes
import VectorizeRoutes
import AnalyticsRoutes
import HyperdriveRoutes
import WorkflowsRoutes
import AssetsRoutes
import VersionRoutes
import SecretsStoreRoutes
import ObjectRoutes
import RpcRoutes
import RpcErrRoutes
import CborRoutes
import WebSocketRoutes
import TcpRoutes
import AfterRoutes

fetch! : Request => Try(Response, _)
fetch! = |req| {
	# 8h item 1: an `Err` of `fetch!` has its own error type, here `FetchFail(Str)`.
	if req.segments() == ["fail"] {
		return Err(FetchFail("fetch"))
	}
	res = match req.segments() {
		["http", .. as rest] => HttpRoutes.route!(req, rest)
		["env", .. as rest] => EnvRoutes.route!(req, rest)
		["time", .. as rest] => TimeRoutes.route!(req, rest)
		["log", .. as rest] => LogRoutes.route!(req, rest)
		["ratelimit", .. as rest] => RateLimitRoutes.route!(req, rest)
		["cf", .. as rest] => CfRoutes.route!(req, rest)
		["shim", .. as rest] => ShimRoutes.route!(req, rest)
		["webcrypto", .. as rest] => WebCryptoRoutes.route!(req, rest)
		["r2", .. as rest] => R2Routes.route!(req, rest)
		["cache", .. as rest] => CacheRoutes.route!(req, rest)
		["d1", .. as rest] => D1Routes.route!(req, rest)
		["memo", .. as rest] => MemoRoutes.route!(req, rest)
		["pin", .. as rest] => PinRoutes.route!(req, rest)
		["queue", .. as rest] => QueueRoutes.route!(req, rest)
		["kv", .. as rest] => KvRoutes.route!(req, rest)
		["email", .. as rest] => EmailRoutes.route!(req, rest)
		["ai", .. as rest] => AiRoutes.route!(req, rest)
		["vectorize", .. as rest] => VectorizeRoutes.route!(req, rest)
		["analytics", .. as rest] => AnalyticsRoutes.route!(req, rest)
		["hyperdrive", .. as rest] => HyperdriveRoutes.route!(req, rest)
		["workflows", .. as rest] => WorkflowsRoutes.route!(req, rest)
		["assets", .. as rest] => AssetsRoutes.route!(req, rest)
		["version", .. as rest] => VersionRoutes.route!(req, rest)
		["secretsstore", .. as rest] => SecretsStoreRoutes.route!(req, rest)
		["objects", .. as rest] => ObjectRoutes.route!(req, rest)
		["rpc", .. as rest] => RpcRoutes.route!(req, rest)
		["rpcerr", .. as rest] => RpcErrRoutes.route!(req, rest)
		["cbor", .. as rest] => CborRoutes.route!(req, rest)
		["websocket", .. as rest] => WebSocketRoutes.route!(req, rest)
		["tcp", .. as rest] => TcpRoutes.route!(req, rest)
		["after", .. as rest] => AfterRoutes.route!(req, rest)
		_ => Response.from_text(404, "no route")
	}
	Ok(res)
}

# 8h item 1: `scheduled!` has the error type `[UnknownCron(Str)]`, `queue!` and `email!` have `[Boom]`, `fetch!` has `[FetchFail(Str)]`.
scheduled! : Worker.Scheduled => Try({}, [UnknownCron(Str)])
scheduled! = |s| if s.cron == "bad" Err(UnknownCron(s.cron)) else Ok({})

queue! = |batch| QueueRoutes.consume!(batch)

email! = |mail| EmailRoutes.handle!(mail)

tail! = |items| TailRoutes.handle!(items)

# Wave B issue 5: a cron with its own handler (checks/cron.mjs). A run of "bad" or "good" goes to `scheduled!` above.
cron_a! : Worker.Scheduled => Try({}, [CronA])
cron_a! = |s| {
	Log.info!("cron handler", { cron: s.cron })
	Ok({})
}

# Wave B issue 5: the bindings that the shim checks at load (checks/cron.mjs, checks/bindings.mjs): the options of `checks/d1.mjs`, `kv.mjs`, `objects.mjs`.
bindings = [D1.binding("DB").declare(), Kv.text("KV").declare(), Object.namespace("COUNTERS", { class: "Counter" }).declare()]

worker = Worker.new({ fetch!, scheduled!, queue!, email!, tail!, rpc: RpcRoutes.rpc, entrypoints: RpcRoutes.entrypoints.concat(AfterRoutes.entrypoints), objects: ObjectRoutes.classes.concat(WebSocketRoutes.classes), bindings, crons: [Worker.cron("cron-a", cron_a!)] })

event! = |e| worker.event!(e)
