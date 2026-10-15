## An app on the module API of MODULES.md, with the fake JS side of `Io.roc`. Typed data crosses as CBOR.
## `main!` sends fake events through `Worker.event!` and prints each outcome.
import Io
import Body
import Request
import Response
import Http
import Env
import Sql
import D1
import Kv
import R2
import Queue
import Rpc
import Object
import Memo
import WebCrypto
import Ctx
import Worker
import WebSocket
import Cbor

# Declarations (MODULES.md MC1): pure constants, no init step.
Pkg : { name : Str, version : Str }
Prefs : { theme : Str }
Job : { pkg : Str, attempt : U32 }
Jwks : { keys : List({ kid : Str, n : Str }) }

db = D1.binding("DB")

prefs : Kv(Prefs)
prefs = Kv.json("PREFS")

theme = prefs.cell("prefs")

tiles = R2.binding("TILES")

jobs : Queue(Job)
jobs = Queue.json("JOBS")

counters = Object.namespace("COUNTERS")

rooms = Object.namespace("ROOMS")

User : { name : Str }

increment : Rpc({ by : I64 }, I64)
increment = Rpc.method("increment")

current : Rpc({}, I64)
current = Rpc.method("current")

count : Object.Cell(I64)
count = Object.cell("count")

jwks : Memo(Jwks, [HttpErr(Io.Thrown), BadData(Str), TooLarge])
jwks = Memo.new("github-jwks", { max_age_ms: 3_600_000, load!: load_jwks! })

# The annotation is necessary: with no annotation, the result type has a `Json` constraint
# (`res.json!()`) and `Memo.new` adds a `Cbor` one, and the checker says that the type is
# not determined (nightlies 10-09 and 10-12).
load_jwks! : {} => Try(Jwks, [HttpErr(Io.Thrown), BadData(Str), TooLarge])
load_jwks! = |{}| {
	res = Http.send!(Request.get("https://token.actions.githubusercontent.com/.well-known/jwks"))?
	res.json!()
}

# Handlers.
fetch! : Request => Try(Response, _)
fetch! = |req| match (req.method, req.segments()) {
	(GET, ["v1", "pkg"]) => {
		pkgs : List(Pkg)
		pkgs = db.all!("select name, version from pkg order by name", [])?
		Ok(Response.from_json(200, pkgs))
	}
	(GET, ["v1", "pkg", owner, name]) => {
		pkg : Pkg
		pkg = db.first!("select name, version from pkg where name = ?", [Text("${owner}/${name}")])?
		Ok(Response.from_json(200, pkg))
	}
	(GET, ["v1", "both"]) => {
		# Two operations in one crossing (`Par`): the error unions join.
		(pkgs, p) = Io.both!(db.all("select name from pkg", []), prefs.get("prefs"))?
		n : List(Pkg)
		n = pkgs
		Ok(Response.from_text(200, "${n.len().to_str()} ${p.theme}"))
	}
	(GET, ["v1", "theme"]) => {
		p = theme.get!()?
		Ok(Response.from_text(200, p.theme))
	}
	(POST, ["v1", "publish"]) => {
		token = Env.secret!("GITHUB_TOKEN")?
		keys = jwks.get!()?
		WebCrypto.verify!({ alg: RsaPkcs1(Sha256), key: Jwk("{}"), signature: "good".to_utf8(), data: [] })?
		job : Job
		job = req.json!()?
		meta = tiles.put_with!("checkpoint", Body.Text("cp"), { only_if: EtagIs("etag-1") })?
		jobs.send!(job)?
		Ctx.respond!(Response.from_text(202, "queued"))
		Ctx.wait_until!(jobs.send(job))
		Ok(Response.from_text(202, "${Str.inspect(token)} ${keys.keys.len().to_str()} ${meta.etag}"))
	}
	(POST, ["v1", "cas"]) => {
		_ = tiles.put_with!("checkpoint", Body.Text("cp"), { only_if: EtagIs("old") })?
		Ok(Response.from_status(204))
	}
	# A WebSocket: the object accepts it, and its 101 response goes back to the client (MODULES.md 12.1).
	(GET, ["room", name]) if WebSocket.is_upgrade(req) => rooms.named(name).fetch!(req)
	(GET, ["room", _]) => Ok(Response.from_status(426))
	# A WebSocket in the Worker: a loop of `receive!` after `respond!` (MODULES.md 12.2).
	(GET, ["echo"]) => {
		{ socket, response } = WebSocket.accept!(req)?
		Ctx.respond!(response)
		while Bool.True {
			match socket.receive!() {
				Ok(Text(t)) => socket.send!(Text("echo ${t}")) ?? {}
				Ok(Bytes(_)) => {}
				Err(Closed(_)) => break
			}
		}
		Ok(response)
	}
	(POST, ["v1", "count"]) => {
		n = counters.named("global").call!(increment, { by: 1 })?
		Ok(Response.from_text(200, n.to_str()))
	}
	_ => Ok(Response.from_status(404))
}

queue! = |batch| {
	n = jobs.each!(batch, |job| if job.attempt > 2 Err(GiveUp(job.pkg)) else Ok({}))
	echo!("queue ${batch.queue}: acked ${n.acked.to_str()}, retried ${n.retried.to_str()}\n")
	Ok({})
}

counter = Object.class("Counter", {
	rpc: [
		increment.on(|self, { by }| {
			old = count.get!(self) ?? 0
			count.set!(self, old + by)?
			Ok(old + by)
		}),
		current.on(|self, {}| Ok(count.get!(self) ?? -1)),
	],
})

room = Object.class("Room", {
	fetch!: |self, r| {
		{ socket, response } = self.accept!(r)?
		user : User
		user = { name: "ann" }
		socket.attach!(user)?
		Ok(response)
	},
	web_socket_message!: |self, socket, msg| {
		user : User
		user = socket.attachment!()?
		said : { text : Str }
		said = msg.json()?
		for peer in self.sockets!() {
			if peer != socket {
				_ = peer.send_json!({ user: user.name, text: said.text })
				echo!("sent to socket ${peer.ref.to_str()}\n")
			}
		}
		Ok({})
	},
	web_socket_close!: |_self, socket, closed| {
		socket.close!(closed.code, closed.reason)
		Ok({})
	},
})

worker = Worker.{ fetch!, queue!, objects: [counter, room] }

# The fake runtime.
req = |method, url, body| Request.{ method, url, body: Body.Text(body) }

upgrade = |url| Request.{ method: GET, url, headers: [("Upgrade", "websocket")] }

show = |outcome| match outcome {
	Respond(res) => res.summary()
	Reply(bytes) => {
		# JS gives the caller the reply as a JS value. Here every reply is an I64.
		n : Try(I64, _)
		n = Cbor.parse(bytes)
		"reply ${Str.inspect(n ?? 0)}"
	}
	Done => "done"
	Failed(msg) => "failed: ${msg}"
	Unhandled => "unhandled"
}

main! = |_args| {
	events = [
		Fetch(req(GET, "https://r.dev/v1/pkg", "")),
		Fetch(req(GET, "https://r.dev/v1/pkg/a/b?x=1", "")),
		Fetch(req(GET, "https://r.dev/v1/pkg/a/zz", "")),
		Fetch(req(GET, "https://r.dev/v1/both", "")),
		Fetch(req(GET, "https://r.dev/v1/theme", "")),
		Fetch(req(POST, "https://r.dev/v1/publish", "{\"pkg\":\"a/b\",\"attempt\":1}")),
		Fetch(req(POST, "https://r.dev/v1/publish", "{\"pkg\":\"a/b\"}")),
		Fetch(req(POST, "https://r.dev/v1/cas", "")),
		Fetch(req(POST, "https://r.dev/v1/count", "")),
		Fetch(req(GET, "https://r.dev/nope", "")),
		Fetch(upgrade("https://r.dev/room/r1")),
		Fetch(req(GET, "https://r.dev/room/r1", "")),
		Fetch(upgrade("https://r.dev/echo")),
		Object("Room", "name:r1", Fetch(upgrade("https://r.dev/room/r1"))),
		Object("Room", "name:r1", Fetch(req(GET, "https://r.dev/room/r1", ""))),
		Object("Room", "name:r1", SocketMessage(Object.Socket.{ ref: 7 }, Text("{\"text\":\"hi\"}"))),
		Object("Room", "name:r1", SocketMessage(Object.Socket.{ ref: 8 }, Text("{\"text\":\"hi\"}"))),
		Object("Room", "name:r1", SocketClose(Object.Socket.{ ref: 7 }, { code: 1000, reason: "bye", clean: Bool.True })),
		Queue({ queue: "jobs", messages: [{ id: "1", body: Cbor.encode({ pkg: "a", attempt: 1.U32 }), attempts: 1 }, { id: "2", body: Cbor.encode({ pkg: "b", attempt: 3.U32 }), attempts: 3 }, { id: "3", body: Cbor.encode("bad"), attempts: 1 }] }),
		Rpc("nope", Cbor.encode({})),
		Object("Counter", "name:global", Rpc("increment", Cbor.encode({ by: 5.I64 }))),
		Object("Counter", "name:global", Rpc("increment", Cbor.encode({ bad: 5.I64 }))),
		Object("Counter", "name:global", Rpc("current", Cbor.encode({}))),
		Object("Counter", "name:global", Alarm),
		Scheduled({ cron: "* * * * *", time_ms: 0 }),
	]
	for ev in events {
		echo!("${show(worker.event!(ev))}\n")
	}
	Ok({})
}
