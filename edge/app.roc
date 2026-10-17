app [event!] {
	pf: platform "../bench/platform/main.roc",
	http: "https://github.com/roc-lang/http/releases/download/2.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
}

## The edge app (PLAN.md 11c): the conformance app (PLAN.md 8c) and `EdgeRoutes.roc`. `edge/build.sh` copies the route files
## of `conformance/` here. The conformance app (PLAN.md 8c): one route for each function of a module and for its `Io` twin. `run.mjs` runs it
## in Miniflare and checks each answer. A route is `/<module>/<function>`. Each module has its routes in its own file
## (`<Module>Routes.roc`, a function `route!`) and one line below. README.md says how to add a module.
import pf.Worker
import pf.Request
import pf.Response
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
import CborRoutes
import WebSocketRoutes
import TcpRoutes
import EdgeRoutes

fetch! : Request => Try(Response, _)
fetch! = |req| {
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
		["cbor", .. as rest] => CborRoutes.route!(req, rest)
		["websocket", .. as rest] => WebSocketRoutes.route!(req, rest)
		["tcp", .. as rest] => TcpRoutes.route!(req, rest)
		["edge", .. as rest] => EdgeRoutes.route!(req, rest)
		_ => Response.from_text(404, "no route")
	}
	Ok(res)
}

queue! = |batch| QueueRoutes.consume!(batch)

email! = |mail| EmailRoutes.handle!(mail)

tail! = |items| TailRoutes.handle!(items)

worker = Worker.{ fetch!, scheduled!: EdgeRoutes.scheduled!, queue!, email!, tail!, rpc: RpcRoutes.rpc, entrypoints: RpcRoutes.entrypoints, objects: ObjectRoutes.classes.concat(WebSocketRoutes.classes) }

event! = |e| worker.event!(e)
