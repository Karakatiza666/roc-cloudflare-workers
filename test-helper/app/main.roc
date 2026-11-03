app [event!] { pf: platform "../../platform/main.roc" }

## The app of the test helper tests (test-helper/helper-test.mjs, research/design-notes/test-helper.md 7, H2). It runs on the
## production host. Each route uses one binding kind, so a test can check the helper with the real shim and the real wasm.
##
## | Route | Shows |
## | --- | --- |
## | `/now` | `Time.now_ms!` (the shim clock, option `now`) |
## | `/d1/count`, `/d1/add?v=`, `/d1/three`, `/d1/session?b=` | D1: a read, a write, 1 batch and 2 all (3 calls), a read in a session |
## | `/slow?ms=` | a sleep, then one D1 read (two requests at the same time, TH4) |
## | `/kv/get?k=`, `/kv/put?k=&v=` | KV |
## | `/r2/get?k=`, `/r2/put?k=&v=` | R2 |
## | `/cache/get?url=&name=`, `/cache/put?url=&name=&v=` | the Cache API (`name` empty: `caches.default`) |
## | `/memo` | a `Memo` of 60 s: the id of the load |
## | `/after?k=` | `Response.after`: the work writes the KV key `k` after 200 ms |
## | `/room/bump?name=` | an Rpc call to the object `name` of `Room` (`init!` runs at the first event) |
## | `/room/alarm?name=` | the object sets an alarm in 10 ms; the alarm writes the KV key `alarm` |
## | `/send?n=` | a queue message to `JOBS`; the consumer writes the KV key `job-<n>` |
## | `/send_batch?n=` | `sendBatch` of 2 messages to `JOBS` (`n` and `n + 1`) |
## | `/send_delay?n=&ms=` | a queue message to `JOBS` with `delay_ms` (`delaySeconds`: whole seconds, rounded up) |
## | `/limit?k=` | `LIMITER.limit({ key })`: `allowed` or `limited` |
## | `/out?url=`, `/out_max?url=&max=` | an outbound fetch: the status, the body length, the Content-Length header |
## | `/echo` | the method, the headers `content-type`, `cache-control`, `pragma`, and the body |
## | `/header?name=` | one request header, or `none` |
## | `/var?name=` | `Env.var!` |
## | `/redirect` | a 302 to `/` |
import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Sql
import pf.Kv
import pf.R2
import pf.Cache
import pf.Memo
import pf.Queue
import pf.RateLimit
import pf.Object
import pf.Rpc
import pf.Time
import pf.Http
import pf.Env
import pf.WebCrypto
import pf.WebSocket

db = D1.binding("DB")

store : Kv(Str)
store = Kv.text("KV")

bucket = R2.binding("BUCKET")

Job : { n : U64 }

limiter = RateLimit.binding("LIMITER")

jobs : Queue(Job)
jobs = Queue.json("JOBS")

Loaded : { id : Str }

memo : Memo(Loaded)
memo = Memo.new("helper-memo", { max_age_ms: 60_000 })

load! : () => Try(Loaded, [LoadErr])
load! = || Ok({ id: WebCrypto.random_uuid!() })

RoomApi := []

room_iface : Rpc.Iface(RoomApi)
room_iface = Rpc.iface("Room")

bump : Rpc(RoomApi, { by : I64 }, I64, Rpc.NoErr)
bump = room_iface.method("bump")

room_class : Object.Class(RoomApi)
room_class = Object.class("Room", { init!: room_init!, fetch!: room_fetch!, alarm!: room_alarm!, web_socket_message!: room_message!, rpc: [bump.on(room_bump!)] })

rooms : Object.Namespace(RoomApi)
rooms = Object.namespace("ROOMS", { class: room_class })

q : Request, Str -> Str
q = |req, name| req.query(name) ?? ""

num : Request, Str -> U64
num = |req, name| U64.from_str(req.query(name) ?? "0") ?? 0

ok : Str -> Response
ok = |text| Response.from_text(200, text)

show : Try(a, e) -> Response
show = |r| match r {
	Ok(v) => ok("Ok ${Str.inspect(v)}")
	Err(e) => ok("Err ${Str.inspect(e)}")
}

fetch! : Request => Try(Response, _)
fetch! = |req| {
	res = match req.segments() {
		[] => ok("helper app")
		["now"] => ok(Time.now_ms!().to_str())
		["d1", "count"] => {
			got : Try({ n : I64 }, _)
			got = db.first!("SELECT count(*) AS n FROM items", Sql.none)
			show(got)
		}
		["d1", "add"] => show(db.run!("INSERT INTO items (v) VALUES (?)", [q(req, "v")]).map_ok(|_| {}))
		["d1", "three"] => {
			_ = db.batch!([Sql.stmt("SELECT 1 AS one", Sql.none)])
			a : Try(List({ n : I64 }), _)
			a = db.all!("SELECT count(*) AS n FROM items", Sql.none)
			b : Try(List({ n : I64 }), _)
			b = db.all!("SELECT count(*) AS n FROM items", Sql.none)
			show(Ok((a.is_ok(), b.is_ok())))
		}
		["d1", "session"] => match db.with_session!(After(q(req, "b"))) {
			Ok(s) => {
				got : Try(List({ n : I64 }), _)
				got = s.all!("SELECT count(*) AS n FROM items", Sql.none)
				show(got)
			}
			Err(e) => show(Err(e))
		}
		["slow"] => {
			Time.sleep!(num(req, "ms"))
			got : Try({ n : I64 }, _)
			got = db.first!("SELECT count(*) AS n FROM items", Sql.none)
			show(got)
		}
		["kv", "get"] => show(store.get!(q(req, "k")))
		["kv", "put"] => show(store.put!(q(req, "k"), q(req, "v")))
		["r2", "get"] => match bucket.get!(q(req, "k")) {
			Ok(obj) => match obj.body.text!() {
				Ok(t) => ok("Ok ${t}")
				Err(e) => show(Err(e))
			}
			Err(e) => show(Err(e))
		}
		["r2", "put"] => show(bucket.put!(q(req, "k"), Text(q(req, "v"))).map_ok(|_| {}))
		["cache", "get"] => {
			cache = if (q(req, "name") == "") Cache.default else Cache.named(q(req, "name"))
			match cache.get!(q(req, "url")) {
				Ok(hit) => match hit.text!() {
					Ok(t) => ok("Ok ${t}")
					Err(e) => show(Err(e))
				}
				Err(e) => show(Err(e))
			}
		}
		["cache", "put"] => {
			cache = if (q(req, "name") == "") Cache.default else Cache.named(q(req, "name"))
			show(cache.put!(q(req, "url"), Response.from_text(200, q(req, "v")).with_header("cache-control", "max-age=3600")).map_ok(|_| {}))
		}
		["memo"] => show(memo.get!(load!))
		["after"] => {
			key = q(req, "k")
			ok("early").after(
				|| {
					Time.sleep!(200)
					store.put!(key, "done")
				},
			)
		}
		["room", "bump"] => show(rooms.named(q(req, "name")).call!(bump, { by: 1 }))
		["room", "alarm"] => match rooms.named(q(req, "name")).fetch!(Request.get("http://o/alarm")) {
			Ok(r) => ok("Ok ${r.text!() ?? "?"}")
			Err(e) => show(Err(e))
		}
		["send"] => show(jobs.send!({ n: num(req, "n") }))
		["send_batch"] => show(jobs.send_batch!([{ n: num(req, "n") }, { n: num(req, "n") + 1 }]))
		["send_delay"] => show(jobs.send_with!({ n: num(req, "n") }, { delay_ms: num(req, "ms") }))
		["limit"] => match limiter.limit!(q(req, "k")) {
			Ok({}) => ok("allowed")
			Err(RateLimited) => ok("limited")
			Err(e) => show(Err(e))
		}
		["out"] => match Http.get!(q(req, "url")) {
			Ok(r) => {
				cl = r.header("content-length") ?? "none"
				match r.bytes!() {
					Ok(b) => ok("status=${r.status().to_str()} len=${b.len().to_str()} cl=${cl}")
					Err(e) => show(Err(e))
				}
			}
			Err(e) => show(Err(e))
		}
		["out_max"] => match Http.send_with!(Request.get(q(req, "url")), { max_bytes: num(req, "max") }) {
			Ok(r) => match r.bytes!() {
				Ok(b) => ok("len=${b.len().to_str()}")
				Err(e) => show(Err(e))
			}
			Err(e) => show(Err(e))
		}
		["echo"] => {
			h = |name| req.header(name) ?? "-"
			body = req.text!() ?? "?"
			ok("${Str.inspect(req.method())} ct=${h("content-type")} cc=${h("cache-control")} pragma=${h("pragma")} body=${body}")
		}
		["header"] => ok(req.header(q(req, "name")) ?? "none")
		["var"] => show(Env.var!(q(req, "name")))
		["redirect"] => Response.redirect(302, "/")
		_ => Response.from_text(404, "no route")
	}
	Ok(res)
}

room_init! : Object.Self => Try({}, _)
room_init! = |self| {
	_ = self.sql_run!("CREATE TABLE IF NOT EXISTS hits (n INTEGER)", Sql.none)?
	Ok({})
}

room_fetch! : Object.Self, Request => Try(Response, [])
room_fetch! = |self, req| match req.segments() {
	["alarm"] => Ok(ok(Str.inspect(self.set_alarm_in!(10))))
	_ => Ok(Response.from_text(404, "no route"))
}

room_alarm! : Object.Self, { retry_count : U32, is_retry : Bool } => Try({}, _)
room_alarm! = |_self, _info| store.put!("alarm", "rang")

## A socket message (the event kind `Socket` of `wrapEnv`, bench/wrapenv-test.mjs): nothing to do.
room_message! : Object.Self, Object.Socket, WebSocket.Message => Try({}, [])
room_message! = |_self, _socket, _msg| Ok({})

room_bump! : Object.Self, { by : I64 } => Try(I64, Rpc.NoErr)
room_bump! = |_self, { by }| Ok(by)

scheduled! : Worker.Scheduled => Try({}, _)
scheduled! = |s| store.put!("cron", "${s.time_ms().to_str()} ${Time.now_ms!().to_str()}")

queue! : Queue.Batch => Try({}, [])
queue! = |batch| {
	_ = jobs.each!(batch, |_msg, job| store.put!("job-${job.n.to_str()}", Time.now_ms!().to_str()))
	Ok({})
}

bindings = [db.declare(), store.declare(), bucket.declare(), jobs.declare(), limiter.declare(), rooms.declare()]

worker = Worker.new({ fetch!, scheduled!, queue!, objects: [room_class.erase()], bindings, crons: [] })

event! = |e| worker.event!(e)
