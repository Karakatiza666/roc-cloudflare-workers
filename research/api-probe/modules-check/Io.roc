## `Io` (API.md 6.5) over a fake JS side. Here an op is a string, and the result of JS is the
## CBOR of a value (API.md 5): a typed read arrives packed (tag 24), so the module decodes it
## with `Cbor.parse` into the type of the caller. The real `Io` sends `Op`s through `await!`.
import Cbor

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
}

run_one : Io(a, e) -> Try(a, e)
run_one = |io| {
	read = io.read
	read(cross(io.ops))
}

## The fake JS side. Pure, so it can stand in for `await!` in this check.
cross! : List(Str) => Try(List(U8), Thrown)
cross! = |ops| cross(ops)

Pkg : { name : Str, version : Str }

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
	["d1.run", ..] => Ok(Cbor.encode({ changes: 1.U64, last_row_id: 7.I64 }))
	# KV holds JSON text (Kv.json), so JS gives a string.
	["kv.get", _, "prefs", ..] => Ok(Cbor.encode("{\"theme\":\"dark\"}"))
	["kv.get", ..] => Ok(Io.null)
	["r2.put", _, _, "etag-1"] => Ok(Cbor.encode({ etag: "etag-2", size: 3.U64 }))
	["r2.put", _, _, "absent"] => Ok(Cbor.encode({ etag: "etag-1", size: 3.U64 }))
	["r2.put", ..] => Ok(Io.null)
	["memo.pinned", ..] => Ok(Io.null)
	["http.send", "https://token.actions.githubusercontent.com/.well-known/jwks"] => Ok(Cbor.encode({ status: 200.U16, body: "{\"keys\":[{\"kid\":\"k1\",\"n\":\"abc\"}]}" }))
	["crypto.verify", _, "good", ..] => Ok(Cbor.encode(Bool.True))
	["crypto.verify", ..] => Ok(Cbor.encode(Bool.False))
	["rpc", "object", _, _, "increment", _] => Ok(Cbor.encode(6.I64))
	["env.secret", "GITHUB_TOKEN"] => Ok(Cbor.encode("ghs_123"))
	["env.secret", ..] => Ok(Io.null)
	["object.fetch", ..] => Ok(Cbor.encode({ status: 101.U16, web_socket: 9.U32 }))
	["do.accept", ..] => Ok(Cbor.encode({ server: 7.U32, client: 9.U32 }))
	["do.sockets", ..] => Ok(Cbor.encode([7.U32, 8, 12]))
	["ws.accept"] => Ok(Cbor.encode(20.U32))
	["ws.attachment", "7"] => Ok(Cbor.encode({ name: "ann" }))
	["boom", ..] => Err({ name: "TypeError", message: "boom" })
	_ => Ok(Io.null)
}
