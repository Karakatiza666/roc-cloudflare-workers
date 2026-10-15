## `Io` (API.md 6.5) over a fake JS side. Here an op is a string, and the result of JS is the
## CBOR of a value (API.md 5): a typed read arrives packed (tag 24), so the module decodes it
## with `Cbor.parse` into the type of the caller. The real `Io` sends `Op`s through `await!`.
import Cbor
import Sql
import Request

Io(a, e) := { ops : List(Str), read : Try(List(U8), Thrown) -> Try(a, e) }.{
	new : List(Str), (Try(List(U8), Thrown) -> Try(a, e)) -> Io(a, e)
	new = |ops, read| { ops, read }

	## An operation whose result is a value of type `a`. `wrap` turns a throw into the error of the module.
	typed : List(Str), (Thrown -> [BadData(Str), ..e]) -> Io(a, [BadData(Str), ..e])
		where [a.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	typed = |ops, wrap| new(ops, |r| match r {
		Ok(bytes) => Io.decode(bytes)
		Err(t) => Err(wrap(t))
	})

	## A result that the platform reads as a `Js` tree, so its errors have no `BadData`.
	## In the fake it is CBOR: a value that does not fit is the throw "BadData".
	tree : List(Str), (Thrown -> e) -> Io(a, e) where [a.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	tree = |ops, wrap| new(ops, |r| match r {
		Ok(bytes) => match Cbor.parse(bytes) {
			Ok(v) => Ok(v)
			Err(err) => Err(wrap({ name: "BadData", message: Str.inspect(err) }))
		}
		Err(t) => Err(wrap(t))
	})

	map : Io(a, e), (a -> b) -> Io(b, e)
	map = |io, f| {
		read = io.read
		{ ops: io.ops, read: |r| read(r).map_ok(f) }
	}

	run! : Io(a, e) => Try(a, e)
	run! = |io| {
		read = io.read
		read(cross!(io.ops))
	}

	## One crossing with `Par` in the real module. Here: two fake crossings.
	both! : Io(a, e), Io(b, e) => Try((a, b), e)
	both! = |x, y| {
		a = x.run!()?
		b = y.run!()?
		Ok((a, b))
	}

	all! : List(Io(a, e)) => List(Try(a, e))
	all! = |ios| ios.map(|io| run_one(io))

	## One crossing with `Race` (OP8). The fake runs the branch with the shortest fake time (`latency`).
	race! : List(Io(a, e)) => { index : U64, result : Try(a, e) }
	race! = |ios| {
		waits = ios.map(|io| latency(io.ops))
		index = match waits.min() {
			Ok(m) => waits.find_first_index(|w| w == m) ?? 0
			Err(_) => crash "a Race with no branch is a bad program (status 3)"
		}
		match ios.get(index) {
			Ok(io) => { index, result: io.run!() }
			Err(_) => crash "a Race with no branch is a bad program (status 3)"
		}
	}

	## What JS threw: `Error(name, message)` (API.md 5).
	Thrown : { name : Str, message : Str }

	## CBOR to a value of the type that the caller wants.
	decode : List(U8) -> Try(a, [BadData(Str), ..e]) where [a.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	decode = |bytes| match Cbor.parse(bytes) {
		Ok(v) => Ok(v)
		Err(e) => Err(BadData(Str.inspect(e)))
	}

	## The CBOR of JS `null`: a missing value (MC8).
	null : List(U8)
	null = [0xf6]

	## A value as an op argument of the fake: the real module sends the bytes (`Packed`, API.md 5).
	arg : a -> Str where [a.Cbor.Encodable([])]
	arg = |v| Str.inspect(Cbor.encode(v))

	## The read limit (MC11) as the last op. A `pf` helper stops at it (API.md 6.4).
	max : U64 -> Str
	max = |n| "max:${n.to_str()}"

	## The throw of a `pf` helper past the limit. The module turns it into `TooLarge`.
	too_large : Thrown -> Bool
	too_large = |t| t.name == "TooLarge"
}

run_one : Io(a, e) -> Try(a, e)
run_one = |io| {
	read = io.read
	read(limit(io.ops, cross(io.ops)))
}

## The fake JS side. It writes the ops that a test must see (`visible`) with `dbg`, so they
## go to stderr in order with the output. `run.sh` reads them as the fake shim.
cross! : List(Str) => Try(List(U8), Thrown)
cross! = |ops| {
	if visible(ops) {
		dbg Str.join_with(["js"].concat(ops), " ")
		{}
	}
	limit(ops, cross(ops))
}

visible : List(Str) -> Bool
visible = |ops| match ops {
	["ctx.respond", ..] | ["ctx.pass_through", ..] | ["scheduled.no_retry", ..] => Bool.True
	["queue.ack", ..] | ["queue.retry", ..] | ["queue.retry_all", ..] => Bool.True
	_ => Bool.False
}

## `pf.pack` and `readUpTo` stop at the limit: a larger result is a throw, with no copy (MC11).
limit : List(Str), Try(List(U8), Thrown) -> Try(List(U8), Thrown)
limit = |ops, result| {
	max = match ops.find_first(|o| o.starts_with("max:")) {
		Ok(o) => U64.from_str(o.drop_prefix("max:")) ?? 0
		Err(_) => 0
	}
	match result {
		Ok(bytes) if max > 0 and bytes.len() > max => Err({ name: "TooLarge", message: "${bytes.len().to_str()} bytes, limit ${max.to_str()}" })
		_ => result
	}
}

## The fake time of an op, for `race!`: a sleep takes its ms, a socket read waits 10 s for a message.
latency : List(Str) -> U64
latency = |ops| match ops {
	["time.sleep", ms, ..] => U64.from_str(ms) ?? 0
	["ws.receive", ..] => 10_000
	_ => 0
}

Pkg : { name : Str, version : Str }

r2_meta : Str -> List(U8)
r2_meta = |etag| {
	custom : List((Str, Str))
	custom = []
	# `http` and `checksums` have only some of their optional fields, as R2 gives them.
	Cbor.encode({ key: "k", version: "v1", size_bytes: 3.U64, etag, http_etag: "\"${etag}\"", uploaded_ms: 0.U64, http: { content_type: "text/plain" }, custom, checksums: { md5: [1.U8, 2] } })
}

## A Tail batch as the shim sends it (MODULES.md 3, table "Tail rules"): null and absent fields are `Err(Missing)`.
ShimTraceItem : {
	script_name : Try(Str, [Missing]),
	outcome : Str,
	event_timestamp_ms : Try(U64, [Missing]),
	event : Try({ request : { method : Str, url : Str, headers : List((Str, Str)), cf : Try(Request.Cf, [Missing]) }, response : Try({ status : U16 }, [Missing]) }, [Missing]),
	logs : List({ timestamp_ms : U64, level : Str, message : Str }),
	exceptions : List({ timestamp_ms : U64, name : Str, message : Str }),
}

cf : Request.Cf
cf = {
	asn: Ok(13335),
	as_organization: Err(Missing),
	colo: Ok("WAW"),
	country: Ok("PL"),
	is_eu_country: Bool.True,
	city: Err(Missing),
	continent: Ok("EU"),
	region: Err(Missing),
	region_code: Err(Missing),
	postal_code: Err(Missing),
	metro_code: Err(Missing),
	latitude: Ok("52.2"),
	longitude: Ok("21.0"),
	timezone: Ok("Europe/Warsaw"),
	http_protocol: Ok("HTTP/2"),
	tls_version: Ok("TLSv1.3"),
	tls_cipher: Err(Missing),
	client_tcp_rtt_ms: Err(Missing),
}

tail_shim : List(ShimTraceItem)
tail_shim = [
	{
		script_name: Ok("api"),
		outcome: "ok",
		event_timestamp_ms: Ok(1_700_000_000_000),
		event: Ok({ request: { method: "GET", url: "https://r.dev/v1/pkg", headers: [("accept", "*/*")], cf: Ok(cf) }, response: Ok({ status: 200 }) }),
		logs: [{ timestamp_ms: 1_700_000_000_001, level: "log", message: "[\"hit\",1]" }],
		exceptions: [],
	},
	{
		script_name: Err(Missing),
		outcome: "exception",
		event_timestamp_ms: Err(Missing),
		event: Err(Missing),
		logs: [],
		exceptions: [{ timestamp_ms: 1_700_000_000_002, name: "Error", message: "boom" }],
	},
]


no_meta : List(U8)
no_meta = []

cross : List(Str) -> Try(List(U8), Thrown)
cross = |ops| match ops {
	["d1.all", sql, ..] if sql.contains("from pkg") => {
		rows : List(Pkg)
		rows = [{ name: "a/b", version: "1.2.0" }, { name: "a/c", version: "0.1.0" }]
		Ok(Cbor.encode(rows))
	}
	["d1.first", _, "a/b", ..] => {
		row : Pkg
		row = { name: "a/b", version: "1.2.0" }
		Ok(Cbor.encode(row))
	}
	["d1.first", ..] => Ok(Io.null)
	# D1 gives the SQLite text after "D1_ERROR: " (MODULES.md MC9, table "Named error tags").
	["d1.run", _, "dup", ..] => Err({ name: "Error", message: "D1_ERROR: UNIQUE constraint failed: pkg.name: SQLITE_CONSTRAINT" })
	["d1.run", ..] => Ok(Cbor.encode({ changes: 1.U64, last_row_id: 7.I64, rows_read: 0.U64, rows_written: 1.U64, duration_ms: 0.25.F64 }))
	["d1.session", ..] => Ok(Cbor.encode(30.U32))
	["d1.bookmark", ..] => Ok(Cbor.encode("bm-1"))
	# KV holds JSON text (Kv.json), so JS gives a string.
	["kv.get", _, "prefs", ..] => Ok(Cbor.encode("{\"theme\":\"dark\"}"))
	["kv.get", ..] => Ok(Io.null)
	# Metadata crosses as CBOR, packed apart from the value. No metadata: no bytes.
	["kv.get_meta", _, "prefs", ..] => Ok(Cbor.encode({ value: "{\"theme\":\"dark\"}", metadata: Cbor.encode({ by: "ann" }) }))
	["kv.get_meta", _, "plain", ..] => Ok(Cbor.encode({ value: "{\"theme\":\"light\"}", metadata: no_meta }))
	["kv.get_meta", ..] => Ok(Io.null)
	["kv.list", ..] => Ok(Cbor.encode({ keys: [{ name: "plain", expires_ms: 0.U64, metadata: no_meta }, { name: "prefs", expires_ms: 1_700_000_000_000, metadata: Cbor.encode({ by: "ann" }) }], cursor: "" }))
	["r2.put", _, _, "match:etag-1", ..] => Ok(r2_meta("etag-2"))
	["r2.put", _, _, "none-match:*", ..] => Ok(r2_meta("etag-1"))
	["r2.put", ..] => Ok(Io.null)
	["memo.pinned", ..] => Ok(Io.null)
	["http.send", "https://token.actions.githubusercontent.com/.well-known/jwks", ..] => Ok(Cbor.encode({ status: 200.U16, body: "{\"keys\":[{\"kid\":\"k1\",\"n\":\"abc\"}]}" }))
	# workerd: a scheme that is not http or https is a `TypeError`, a lost connection is an `Error`.
	["http.send", "ftp://r.dev/x", ..] => Err({ name: "TypeError", message: "Fetch API cannot load: ftp://r.dev/x" })
	["http.send", "https://down.r.dev/", ..] => Err({ name: "Error", message: "Network connection lost." })
	["http.send", ..] => Ok(Cbor.encode({ status: 200.U16, body: "ok" }))
	["crypto.import", ..] => Ok(Cbor.encode(40.U32))
	["crypto.verify", _, "good", ..] => Ok(Cbor.encode(Bool.True))
	["crypto.verify", ..] => Ok(Cbor.encode(Bool.False))
	["crypto.equal", a, b] => Ok(Cbor.encode(a == b))
	["crypto.uuid"] => Ok(Cbor.encode("uuid-1"))
	["crypto.random", n] => Ok(Cbor.encode(List.repeat(7.U8, U64.from_str(n) ?? 0)))
	["rpc", "object", _, _, "increment", _] => Ok(Cbor.encode(6.I64))
	["env.secret", "GITHUB_TOKEN"] => Ok(Cbor.encode("ghs_123"))
	["env.secret", ..] => Ok(Io.null)
	["object.fetch", ..] => Ok(Cbor.encode({ status: 101.U16, web_socket: 9.U32 }))
	["object.id", _, _, name] => Ok(Cbor.encode("id-of-${name}"))
	# Local workerd has no jurisdictions (workerd source `server/actor-id-impl.c++`).
	["do.unique", _, "eu", ..] => Err({ name: "Error", message: "Jurisdiction restrictions are not implemented in workerd." })
	["do.unique", ..] => Ok(Cbor.encode("unique-1"))
	["do.accept", ..] => Ok(Cbor.encode({ server: 7.U32, client: 9.U32 }))
	["do.sockets", ..] => Ok(Cbor.encode([7.U32, 8, 12]))
	["do.sql_run", _, sql, ..] if sql.contains("insert") => Err({ name: "Error", message: "UNIQUE constraint failed: hits.day: SQLITE_CONSTRAINT" })
	["do.sql", _, sql, ..] if sql.contains("from hits") => Ok(Cbor.encode([{ day: "mon", n: 3.I64 }, { day: "tue", n: 5.I64 }]))
	["do.sql_run", ..] => Ok(Cbor.encode({ rows_read: 0.U64, rows_written: 0.U64 }))
	["do.sql_rows", ..] => {
		rows : { columns : List(Str), rows : List(List(Sql)) }
		rows = { columns: ["day", "n"], rows: [[Text("mon"), Int(3)], [Text("tue"), Null]] }
		Ok(Cbor.encode(rows))
	}
	["ws.accept"] => Ok(Cbor.encode(20.U32))
	["ws.attachment", "7"] => Ok(Cbor.encode({ name: "ann" }))
	["ws.receive", ..] => Ok(Io.null)
	["tail.batch"] => Ok(Cbor.encode(tail_shim))
	["boom", ..] => Err({ name: "TypeError", message: "boom" })
	_ => Ok(Io.null)
}
