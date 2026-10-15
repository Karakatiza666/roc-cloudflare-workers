## An app on the module API of MODULES.md, with the fake JS side of `Io.roc`. Typed data crosses as CBOR.
## `main!` sends fake events through `Worker.event!` and prints each outcome. `run.sh` is the fake shim:
## after `Ctx.respond!` it prints the response that `respond!` got, and drops the returned one.
import Io
import Js
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
import Time
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

jwks : Memo(Jwks, [Network(Io.Thrown), HttpErr(Io.Thrown), BadData(Str), TooLarge])
jwks = Memo.new("github-jwks", { max_age_ms: 3_600_000, load!: load_jwks! })

# The annotation is necessary: with no annotation, the result type has a `Json` constraint
# (`res.json!()`) and `Memo.new` adds a `Cbor` one, and the checker says that the type is
# not determined (nightlies 10-09 and 10-12).
load_jwks! : {} => Try(Jwks, [Network(Io.Thrown), HttpErr(Io.Thrown), BadData(Str), TooLarge])
load_jwks! = |{}| {
	res = Http.send!(Request.get("https://token.actions.githubusercontent.com/.well-known/jwks"))?
	res.json!()
}

# Typed metadata of a key, read at the use (MODULES.md 5.2).
meta_by : Kv.Key -> Try(Str, [Missing, BadData(Str)])
meta_by = |key| {
	m : { by : Str }
	# `key.metadata?` does not compile: `[Missing]` is closed, so `?` cannot add it to a larger union.
	m = (key.metadata ? |_| Missing).parse()?
	Ok(m.by)
}

# Handlers.
fetch! : Request => Try(Response, _)
fetch! = |req| match (req.method, req.segments()) {
	(GET, ["v1", "pkg"]) => {
		pkgs : List(Pkg)
		pkgs = db.all!("select name, version from pkg order by name", [])?
		Ok(Response.from_json(200, pkgs))
	}
	(GET, ["v1", "pkg", "big"]) => {
		pkgs : List(Pkg)
		pkgs = db.all_with!("select name, version from pkg", [], { max_bytes: 16 })?
		Ok(Response.from_json(200, pkgs))
	}
	(GET, ["v1", "pkg", owner, name]) => {
		pkg : Pkg
		pkg = db.first!("select name, version from pkg where name = ?", [Text("${owner}/${name}")])?
		Ok(Response.from_json(200, pkg))
	}
	(POST, ["v1", "pkg", name]) => {
		info = db.run!("insert into pkg (name) values (?)", [Text(name)])?
		Ok(Response.from_text(201, "changes ${info.changes.to_str()}, row ${info.last_row_id.to_str()}, ${info.duration_ms.to_str()} ms"))
	}
	(GET, ["v1", "session"]) => {
		s = db.with_session!(After("bm-0"))?
		pkg : Pkg
		pkg = s.first!("select name, version from pkg where name = ?", [Text("a/b")])?
		Ok(Response.from_text(200, "${pkg.name} ${s.bookmark!()?}"))
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
	(PUT, ["v1", "prefs"]) => {
		prefs.put_with!("prefs", { theme: "light" }, { ttl_ms: 90_500, metadata: { by: "ann" } })?
		Ok(Response.from_status(204))
	}
	(GET, ["v1", "meta", key]) => {
		got : { value : Prefs, metadata : Try({ by : Str }, [Missing]) }
		got = prefs.get_with_metadata!(key)?
		Ok(Response.from_text(200, "${got.value.theme} by ${got.metadata.map_ok(|m| m.by) ?? "Missing"}"))
	}
	(GET, ["v1", "keys"]) => {
		page = prefs.list!({ prefix: "p" })?
		names = page.keys.map(|k| "${k.name}:${Str.inspect(meta_by(k))}")
		Ok(Response.from_text(200, Str.join_with(names, " ")))
	}
	(POST, ["v1", "publish"]) => {
		token = Env.secret!("GITHUB_TOKEN")?
		keys = jwks.get!()?
		key = WebCrypto.import_key!(RsaPkcs1(Sha256), Jwk("{}"))?
		WebCrypto.verify!({ alg: RsaPkcs1(Sha256), key, signature: "good".to_utf8(), data: [] })?
		job : Job
		job = req.json!()?
		meta = tiles.put_with!("checkpoint", Body.Text("cp"), { only_if: { etag_matches: "etag-1" } })?
		jobs.send!(job)?
		jobs.send_batch!([job, job])?
		id = WebCrypto.random_uuid!({})
		same = WebCrypto.timing_safe_equal!(WebCrypto.random!(2), [7, 7])
		Ctx.respond!(Response.from_text(202, "${Str.inspect(token)} ${keys.keys.len().to_str()} ${meta.etag} ${id} ${Str.inspect(same)}"))?
		Ctx.wait_until!(jobs.send(job))
		# Ignored after respond! (API.md 10.2): the check expects the 202 above, not this 200.
		Ok(Response.from_text(200, "returned"))
	}
	(POST, ["v1", "cas"]) => {
		_ = tiles.put_with!("checkpoint", Body.Text("cp"), { only_if: { etag_matches: "old" } })?
		Ok(Response.from_status(204))
	}
	(PUT, ["v1", "tile", key]) => {
		meta = tiles.put_with!(key, Body.Text("abc"), { only_if: R2.absent, http: { content_type: "text/plain" }, length_bytes: 3 })?
		md5 = meta.checksums.?md5.map_ok(|b| Str.inspect(b)) ?? "none"
		cache = meta.http.?cache_control ?? "no cache_control"
		Ok(Response.from_text(201, "${meta.etag} ${meta.size_bytes.to_str()} ${meta.http.?content_type ?? "?"} ${md5} ${cache}"))
	}
	(POST, ["v1", "count"]) => {
		n = counters.named("global").call!(increment, { by: 1 })?
		Ok(Response.from_text(200, n.to_str()))
	}
	(POST, ["v1", "unique", j]) => {
		obj = if j == "eu" counters.unique_with!({ jurisdiction: Eu })? else counters.unique_with!({ location_hint: Weur })?
		Ok(Response.from_text(200, obj.describe()))
	}
	(GET, ["v1", "id", name]) => {
		a = counters.jurisdiction(Eu).named_with(name, { location_hint: ApacNe }).id!()?
		b = counters.from_id("abc").id!()?
		Ok(Response.from_text(200, "${a} ${b}"))
	}
	(GET, ["v1", "fetch", which]) => Http.get!(if which == "ftp" "ftp://r.dev/x" else "https://down.r.dev/")
	(POST, ["v1", "pass"]) => {
		Ctx.pass_through!({})?
		Err(OriginDown)
	}
	# A WebSocket: the object accepts it, and its 101 response goes back to the client (MODULES.md 12.1).
	(GET, ["room", name]) if WebSocket.is_upgrade(req) => rooms.named(name).fetch!(req)
	(GET, ["room", _]) => Ok(Response.from_status(426))
	# A WebSocket in the Worker: a loop of `receive!` after `respond!` (MODULES.md 12.2).
	(GET, ["echo"]) => {
		{ socket, response } = WebSocket.accept!(req)?
		Ctx.respond!(response)?
		while Bool.True {
			match socket.receive!() {
				Ok(Text(t)) => socket.send!(Text("echo ${t}")) ?? {}
				Ok(Bytes(_)) => {}
				Err(Closed(_)) => break
			}
		}
		Ok(response)
	}
	# A receive with a timeout: a race with a sleep (D4, MODULES.md 12.2).
	(GET, ["wait"]) => {
		{ socket, response } = WebSocket.accept!(req)?
		Ctx.respond!(response)?
		got = Io.race!([socket.receive().map(|m| Got(m)), Time.sleep(5_000).map(|_| TimedOut)])
		text = match got.result {
			Ok(Got(_)) => "message"
			Ok(TimedOut) => "timed out"
			Err(Closed(_)) => "closed"
		}
		echo!("wait: ${text}, branch ${got.index.to_str()}\n")
		socket.close!(1000, "idle")
		Ok(response)
	}
	_ => Ok(Response.from_status(404))
}

# The annotation is necessary: a method call (`no_retry!`) needs the type of the argument.
scheduled! : Worker.Scheduled => Try({}, _)
scheduled! = |job| {
	if job.cron == "0 * * * *" {
		job.no_retry!()
		Err(Stop(job.cron))
	} else {
		Ok({})
	}
}

# `_` would infer the closed `[]` (the handler gives only `Ok`), which does not join the errors of the other handlers.
queue! : Queue.Batch => Try({}, e)
queue! = |batch|
	if batch.queue == "slow" {
		# Low level: the app decides alone (MODULES.md 6).
		for m in batch.messages {
			m.retry_with!({ delay_ms: 2_500 })
		}
		batch.retry_all_with!({ delay_ms: 100_000_000 })
		Ok({})
	} else {
		n = jobs.each!(batch, |msg, job| {
			echo!("job ${job.pkg}: message ${msg.id}, attempts ${msg.attempts.to_str()}\n")
			if msg.attempts > 2 Err(GiveUp(job.pkg)) else Ok({})
		})
		echo!("queue ${batch.queue}: acked ${n.acked.to_str()}, retried ${n.retried.to_str()}\n")
		Ok({})
	}

tail! = |items| {
	for item in items {
		url = match item.event {
			Ok(e) => "${e.request.method} ${e.request.url} ${e.response.map_ok(|r| r.status.to_str()) ?? "-"} cf ${e.request.cf.map_ok(|c| c.colo ?? "?") ?? "none"}"
			Err(Missing) => "no event"
		}
		logs = Str.join_with(item.logs.map(|l| "${l.level} ${l.message}"), "; ")
		echo!("tail ${item.script_name ?? "?"} ${item.outcome}: ${url}; logs ${logs}; exceptions ${item.exceptions.len().to_str()}\n")
	}
	Ok({})
}

counter = Object.class("Counter", {
	init!: |self| {
		info = self.sql_run!("create table if not exists hits (day text primary key, n integer)", [])?
		echo!("init ${self.id()}: ${info.rows_written.to_str()} rows written\n")
		Ok({})
	},
	fetch!: |self, r| match (r.method, r.segments()) {
		(GET, ["hits"]) => {
			rows : List({ day : Str, n : I64 })
			rows = self.sql!("select day, n from hits", [])?
			Ok(Response.from_text(200, Str.join_with(rows.map(|h| "${h.day} ${h.n.to_str()}"), ", ")))
		}
		(GET, ["hits", "raw"]) => {
			t = self.sql_rows!("select day, n from hits", [])?
			Ok(Response.from_text(200, "${Str.join_with(t.columns, ",")}: ${Str.inspect(t.rows)}"))
		}
		(GET, ["hits", "small"]) => {
			t = self.sql_rows_with!("select day, n from hits", [], { max_bytes: 8 })?
			Ok(Response.from_text(200, Str.inspect(t.rows)))
		}
		(POST, ["hits"]) => {
			_ = self.sql_run!("insert into hits (day, n) values (?, ?)", [Text("mon"), Int(1)])?
			Ok(Response.from_status(201))
		}
		_ => Ok(Response.from_status(404))
	},
	rpc: [
		increment.on(|self, { by }| {
			old = count.get!(self) ?? 0
			count.set!(self, old + by)?
			Ok(old + by)
		}),
		current.on(|self, {}| Ok(count.get!(self) ?? -1)),
	],
	# Stop the retries at the third (MODULES.md 7).
	alarm!: |_self, info| if info.retry_count >= 3 Ok({}) else Err(Retry(info.retry_count, info.is_retry)),
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
	web_socket_error!: |_self, socket, thrown| {
		echo!("error on socket ${socket.ref.to_str()}: ${thrown.name}\n")
		socket.close!(1011, thrown.message)
		Ok({})
	},
})

worker = Worker.{ fetch!, scheduled!, queue!, tail!, objects: [counter, room] }

# The fake runtime.
req = |method, url, body| Request.{ method, url, body: Body.Text(body) }

upgrade = |url| Request.{ method: GET, url, headers: [("Upgrade", "websocket")] }

obj = |class, id, event| Object({ class, id, event })

socket = |n| Object.Socket.{ ref: Js.Ref.fake(n) }

message = |id, attempts, body| Queue.Message.{ id, timestamp_ms: 1_700_000_000_000, attempts, body }

# The platform reads the Tail batch from its CBOR (MODULES.md 3, table "Tail rules").
tail_batch! : {} => List(Worker.TraceItem)
tail_batch! = |{}| match Io.run!(Io.typed(["tail.batch"], |t| BadData(t.message))) {
	Ok(items) => items
	Err(BadData(e)) => crash "tail batch: ${e}"
}

show = |outcome| match outcome {
	Respond(res) => res.summary()
	Reply(Packed(bytes)) => {
		# JS gives the caller the reply as a JS value. Here every reply is an I64.
		n : Try(I64, _)
		n = Cbor.parse(bytes)
		"reply ${Str.inspect(n ?? 0)}"
	}
	Reply(_) => "reply (not packed)"
	Done => "done"
	Failed(msg) => "failed: ${msg}"
	Unhandled => "unhandled"
}

main! = |_args| {
	events = [
		Fetch(req(GET, "https://r.dev/v1/pkg", "")),
		Fetch(req(GET, "https://r.dev/v1/pkg/a/b?x=1", "")),
		Fetch(req(GET, "https://r.dev/v1/pkg/a/zz", "")),
		Fetch(req(GET, "https://r.dev/v1/pkg/big", "")),
		Fetch(req(POST, "https://r.dev/v1/pkg/new", "")),
		Fetch(req(POST, "https://r.dev/v1/pkg/dup", "")),
		Fetch(req(GET, "https://r.dev/v1/session", "")),
		Fetch(req(GET, "https://r.dev/v1/both", "")),
		Fetch(req(GET, "https://r.dev/v1/theme", "")),
		Fetch(req(PUT, "https://r.dev/v1/prefs", "")),
		Fetch(req(GET, "https://r.dev/v1/meta/prefs", "")),
		Fetch(req(GET, "https://r.dev/v1/meta/plain", "")),
		Fetch(req(GET, "https://r.dev/v1/keys", "")),
		Fetch(req(POST, "https://r.dev/v1/publish", "{\"pkg\":\"a/b\",\"attempt\":1}")),
		Fetch(req(POST, "https://r.dev/v1/publish", "{\"pkg\":\"a/b\"}")),
		Fetch(req(POST, "https://r.dev/v1/cas", "")),
		Fetch(req(PUT, "https://r.dev/v1/tile/t1", "")),
		Fetch(req(POST, "https://r.dev/v1/count", "")),
		Fetch(req(POST, "https://r.dev/v1/unique/none", "")),
		Fetch(req(POST, "https://r.dev/v1/unique/eu", "")),
		Fetch(req(GET, "https://r.dev/v1/id/global", "")),
		Fetch(req(GET, "https://r.dev/v1/fetch/ftp", "")),
		Fetch(req(GET, "https://r.dev/v1/fetch/down", "")),
		Fetch(req(POST, "https://r.dev/v1/pass", "")),
		Fetch(req(GET, "https://r.dev/nope", "")),
		Fetch(upgrade("https://r.dev/room/r1")),
		Fetch(req(GET, "https://r.dev/room/r1", "")),
		Fetch(upgrade("https://r.dev/echo")),
		Fetch(upgrade("https://r.dev/wait")),
		obj("Room", "name:r1", Init),
		obj("Room", "name:r1", Fetch(upgrade("https://r.dev/room/r1"))),
		obj("Room", "name:r1", Fetch(req(GET, "https://r.dev/room/r1", ""))),
		obj("Room", "name:r1", SocketMessage(socket(7), Text("{\"text\":\"hi\"}"))),
		obj("Room", "name:r1", SocketMessage(socket(8), Text("{\"text\":\"hi\"}"))),
		obj("Room", "name:r1", SocketClose(socket(7), { code: 1000, reason: "bye", clean: Bool.True })),
		obj("Room", "name:r1", SocketError(socket(8), { name: "Error", message: "reset" })),
		Queue(Queue.Batch.{ queue: "jobs", messages: [message("1", 1, Cbor.encode({ pkg: "a", attempt: 1.U32 })), message("2", 3, Cbor.encode({ pkg: "b", attempt: 1.U32 })), message("3", 1, Cbor.encode("bad"))] }),
		Queue(Queue.Batch.{ queue: "slow", messages: [message("9", 1, Cbor.encode({ pkg: "c", attempt: 1.U32 }))] }),
		Tail(tail_batch!({})),
		Rpc("nope", Cbor.encode({})),
		obj("Counter", "name:global", Init),
		obj("Counter", "name:global", Fetch(req(GET, "https://global/hits", ""))),
		obj("Counter", "name:global", Fetch(req(GET, "https://global/hits/raw", ""))),
		obj("Counter", "name:global", Fetch(req(GET, "https://global/hits/small", ""))),
		obj("Counter", "name:global", Fetch(req(POST, "https://global/hits", ""))),
		obj("Counter", "name:global", Rpc({ method: "increment", arg: Cbor.encode({ by: 5.I64 }) })),
		obj("Counter", "name:global", Rpc({ method: "increment", arg: Cbor.encode({ bad: 5.I64 }) })),
		obj("Counter", "name:global", Rpc({ method: "current", arg: Cbor.encode({}) })),
		obj("Counter", "name:global", Alarm({ retry_count: 1, is_retry: Bool.True })),
		obj("Counter", "name:global", Alarm({ retry_count: 3, is_retry: Bool.True })),
		Scheduled(Worker.Scheduled.{ cron: "* * * * *", time_ms: 60_000 }),
		Scheduled(Worker.Scheduled.{ cron: "0 * * * *", time_ms: 3_600_000 }),
	]
	for ev in events {
		echo!("outcome ${show(worker.event!(ev))}\n")
	}
	Ok({})
}
