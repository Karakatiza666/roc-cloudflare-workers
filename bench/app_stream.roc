app [event!] { pf: platform "platform/main.roc" }

## PLAN.md 8b (second half), 9c, 10a, 10b: stream bodies, `Response.after`, `Ctx.pass_through!`, `Ctx.wait_until!`,
## `Body.writer!`, `compress!` and `decompress!`. `bench/stream-test.mjs` (Node) and `bench/stream-workerd.mjs`
## (workerd) send the requests below. The ops of the test (`makeHandler(module, { ops })`): `sleep(ms, signal)`,
## `mark(id, text)`, `put(key, stream)` (a stand-in for a `Cache.named` put: it reads the stream and keeps its bytes),
## `boom()` (throws), `one()` (gives 1).
import pf.Worker
import pf.Request
import pf.Response
import pf.Body
import pf.Ctx
import pf.Io
import pf.Js

## | Request | Answer |
## | --- | --- |
## | POST /pipe | the request body as the response body: a stream, no copy into wasm (10a) |
## | POST /chunk?n= | `chunk!` until `n` bytes or the end: "chunks=<c> bytes=<b>" (10b) |
## | POST /limit?max= | `bytes_with!`: "ok <length>", or "TooLarge" (10b) |
## | POST /tee | `tee!`, both read: "a=<len> b=<len> same=<bool> again=<the read of the first body again>" |
## | POST /sha | `sha256!` of the stream, in hex. With `?bytes=1`: of the bytes in wasm |
## | POST /compress?f=, /decompress?f= | the body through `compress!` or `decompress!` (`gzip`, `deflate`) |
## | GET /ping | "pong": a task, so the shim runs its deadline sweep |
## | GET /after?id= | "early" with `after`: a wait of 100 ms, then `mark(id, "after")` |
## | GET /twice?id= | "first" with two `after` calls: `mark(id, "one")`, then `mark(id, "two")` |
## | GET /deadline?id=&ms= | a `Bytes` body with `after`: a wait of `ms`, then `mark(id, "done")` |
## | GET /stream?id=&n=&gap=&after= | `writer!`, its body with `after`: `n` chunks with `gap` ms after each, `close!`, a wait of `after` ms, `mark(id, "done")` |
## | GET /closed?id= | `writer!`, its body with `after`: `close!`, `write!`: `mark(id, <the result>)` |
## | POST /late?id= | "early" with `after`: a wait of 100 ms, then a read of the request body: an `Err` is `Failed` |
## | GET /pass, /passcrash | `pass_through!`, then `Err(Boom)` or a `crash` |
## | GET /waituntil?id=&ms= | `wait_until!` of a wait of `ms` (with the signal of the task), then `mark(id, "started")` |
## | POST /started?key= | `wait_until!` of a wait of 100 ms, then `put(key, <the request body>)` (9c) |
## | GET /startthrow, /starterr | `wait_until!` of `boom()`, or of an `Io` whose reader gives `Err` |
fetch! : Request => Try(Response, _)
fetch! = |req| match (req.method, req.segments()) {
	(POST, ["pipe"]) => Ok(Response.from_body(200, "application/octet-stream", req.body))
	(POST, ["chunk"]) => {
		want = num(req, "n")
		var $chunks = 0.U64
		var $bytes = 0.U64
		var $more = Bool.True
		while $more and $bytes < want {
			match req.body.chunk!()? {
				Chunk(b) => {
					$chunks = $chunks + 1
					$bytes = $bytes + b.len()
				}
				End => {
					$more = Bool.False
				}
			}
		}
		Ok(Response.from_text(200, "chunks=${$chunks.to_str()} bytes=${$bytes.to_str()}"))
	}
	(POST, ["limit"]) => {
		text = match req.bytes_with!({ max_bytes: num(req, "max") }) {
			Ok(b) => "ok ${b.len().to_str()}"
			Err(TooLarge) => "TooLarge"
			Err(BodyErr(t)) => "BodyErr ${t.name}"
		}
		Ok(Response.from_text(200, text))
	}
	(POST, ["tee"]) => {
		(a, b) = req.body.tee!()?
		ba = a.bytes_with!({ max_bytes: 100_000_000 })?
		bb = b.bytes_with!({ max_bytes: 100_000_000 })?
		again = match req.body.bytes!() {
			Ok(_) => "Ok"
			Err(TooLarge) => "TooLarge"
			Err(BodyErr(t)) => "BodyErr(${t.name})"
		}
		Ok(Response.from_text(200, "a=${ba.len().to_str()} b=${bb.len().to_str()} same=${Str.inspect(ba == bb)} again=${again}"))
	}
	(POST, ["sha"]) => {
		body = if req.query("bytes") == Ok("1") Bytes(req.bytes_with!({ max_bytes: 100_000_000 })?) else req.body
		digest = body.sha256!()?
		Ok(Response.from_text(200, hex(digest)))
	}
	(POST, ["compress"]) => Ok(Response.from_body(200, "application/octet-stream", req.body.compress!(format(req))?))
	(POST, ["decompress"]) => Ok(Response.from_body(200, "application/octet-stream", req.body.decompress!(format(req))?))
	(GET, ["ping"]) => Ok(Response.from_text(200, "pong"))
	(GET, ["after"]) => Ok(
		Response.from_text(200, "early").after(
			|_| {
				sleep!(100)
				mark!(id(req), "after")
				Ok({})
			},
		),
	)
	(GET, ["twice"]) => {
		one! = |_| {
			mark!(id(req), "one")
			Ok({})
		}
		two! = |_| {
			mark!(id(req), "two")
			Ok({})
		}
		Ok(Response.from_text(200, "first").after(one!).after(two!))
	}
	(GET, ["deadline"]) => Ok(
		Response.from_bytes(200, "application/octet-stream", [1, 2, 3]).after(
			|_| {
				sleep!(num(req, "ms"))
				mark!(id(req), "done")
				Ok({})
			},
		),
	)
	(GET, ["stream"]) => {
		{ body, writer } = Body.writer!({})?
		work! = |_| {
			for i in 0.U64.until(num(req, "n")) {
				writer.write_text!("chunk ${i.to_str()}\n")?
				sleep!(num(req, "gap"))
			}
			writer.close!()
			sleep!(num(req, "after"))
			mark!(id(req), "done")
			Ok({})
		}
		Ok(Response.from_body(200, "text/plain", body).after(work!))
	}
	(GET, ["closed"]) => {
		{ body, writer } = Body.writer!({})?
		work! = |_| {
			writer.close!()
			got = match writer.write!([1]) {
				Ok({}) => "Ok"
				Err(BodyErr(t)) => "BodyErr(${t.name})"
			}
			mark!(id(req), got)
			Ok({})
		}
		Ok(Response.from_body(200, "text/plain", body).after(work!))
	}
	(POST, ["late"]) => {
		work! = |_| {
			sleep!(100)
			bytes = req.bytes!()?
			mark!(id(req), "read ${bytes.len().to_str()}")
			Ok({})
		}
		Ok(Response.from_text(200, "early").after(work!))
	}
	(GET, ["pass"]) => {
		Ctx.pass_through!({})?
		Err(Boom)
	}
	(GET, ["passcrash"]) => {
		Ctx.pass_through!({})?
		crash "a crash after pass_through!"
	}
	(GET, ["waituntil"]) => {
		Ctx.wait_until!(Io.new(sleep_ops(num(req, "ms")).append(Call(Root("ops"), "mark", [Lit(Text(id(req))), Lit(Text("started"))])), |r| r.map_ok(|_| {})))
		Ok(Response.from_text(200, "ok"))
	}
	(POST, ["started"]) => {
		key = req.query("key") ?? "none"
		body = match req.body {
			Stream(r) => Ref(r)
			_ => Null
		}
		Ctx.wait_until!(Io.new(sleep_ops(100).append(Call(Root("ops"), "put", [Lit(Text(key)), Lit(body)])), |r| r.map_ok(|_| {})))
		Ok(Response.from_text(200, "ok"))
	}
	(GET, ["startthrow"]) => {
		Ctx.wait_until!(Io.new([Call(Root("ops"), "boom", [])], |r| r.map_ok(|_| {})))
		Ok(Response.from_text(200, "ok"))
	}
	(GET, ["starterr"]) => {
		io : Io({}, [PreconditionFailed, Thrown(Io.Thrown)])
		io = Io.new([Call(Root("ops"), "one", [])], |_| Err(PreconditionFailed))
		Ctx.wait_until!(io)
		Ok(Response.from_text(200, "ok"))
	}
	_ => Ok(Response.from_status(404))
}

## Cron `pass`: `pass_through!` in a `Scheduled` event gives `InvalidState`.
scheduled! : Worker.Scheduled => Try({}, _)
scheduled! = |s| {
	got = match s.cron {
		"pass" => Ctx.pass_through!({})
		other => return Err(UnknownCron(other))
	}
	match got {
		Err(InvalidState) => Ok({})
		Ok({}) => Err(NotInvalidState)
	}
}

## A wait of `ms` with the signal of the task (OP3): it ends at the end of the task, or of its started program.
sleep_ops : U64 -> List(Js.Op)
sleep_ops = |ms| [Keep(Root("signal")), Call(Root("ops"), "sleep", [Lit(Int(ms.to_i64_try() ?? 0)), Slot(0)])]

sleep! : U64 => {}
sleep! = |ms| {
	_ = Io.await!(sleep_ops(ms))
	{}
}

mark! : Str, Str => {}
mark! = |key, text| {
	_ = Io.call!([Call(Root("ops"), "mark", [Lit(Text(key)), Lit(Text(text))])])
	{}
}

id : Request -> Str
id = |req| req.query("id") ?? "none"

num : Request, Str -> U64
num = |req, name| match req.query(name) {
	Ok(s) => U64.from_str(s) ?? 0
	Err(_) => 0
}

format : Request -> Body.Format
format = |req| if req.query("f") == Ok("deflate") Deflate else Gzip

hex : List(U8) -> Str
hex = |bytes| {
	digits = "0123456789abcdef".to_utf8()
	out = bytes.fold([], |acc, b| acc.append(digits.get((b // 16).to_u64()) ?? '0').append(digits.get((b % 16).to_u64()) ?? '0'))
	Str.from_utf8(out) ?? ""
}

worker = Worker.new({ fetch!, scheduled! })

event! : Worker.Event => Worker.Outcome
event! = |e| worker.event!(e)
