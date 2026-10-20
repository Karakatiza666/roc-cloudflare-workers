## Workers KV (MODULES.md 5.2): `env[name]`, one program for each call. The declaration gives the type and the format
## (MC6). `Kv.json` stores JSON text, so a JS Worker reads it with `get(key, "json")`; Roc parses the text itself, so an
## integer above 2^53 stays exact. A read goes through a stream and `pf.readMaybe`, to a limit (MC11): a value above it
## is `TooLarge` before any copy into wasm. Times are whole seconds in KV, so the module rounds up (MC10).
## Typed data: the format, what a JS peer sees, and what survives a round trip are in MODULES.md 1, "Formats of typed data".
import Io
import Js
import Time
import Body
import cbor.Cbor

Kv(a) :: { name : Str, write : a -> Try(Js, Str), read : List(U8) -> Try(a, Str) }.{

	## Values of the type `a`, as JSON text. A value that JSON cannot show (a `NaN` in an `F64`) is `BadData` of the put.
	json : Str -> Kv(a) where [a.Json.Encodable(enc), a.Json.Parseable([InvalidJson(Str), ..errs])]
	json = |name| Kv.{
		name,
		write: |v| Json.to_str_try(v).map_ok(|text| Text(text)).map_err(|e| Str.inspect(e)),
		read: |raw| match Str.from_utf8(raw) {
			Ok(s) => Json.parse(s).map_err(|e| Str.inspect(e))
			Err(_) => Err("the value is not UTF-8")
		},
	}

	## Values that are text, as they are.
	text : Str -> Kv(Str)
	text = |name| Kv.{
		name,
		write: |s| Ok(Text(s)),
		read: |raw| Str.from_utf8(raw).map_err(|_| "the value is not UTF-8"),
	}

	## Values that are bytes, as they are.
	bytes : Str -> Kv(List(U8))
	bytes = |name| Kv.{ name, write: |b| Ok(Bytes(b)), read: |b| Ok(b) }

	## The binding for the manifest (`Worker.new({ bindings: [...] })`, MODULES.md 3): the kind `kv`.
	declare : Kv(a) -> { name : Str, kind : Str, props : List((Str, Str)) }
	declare = |b| { name: b.name, kind: "kv", props: [] }

	## `get(key, { type: "stream" })` and the stream to `Body.default_max` bytes: one wait.
	get : Kv(a), Str -> Io(a, [NotFound, KvErr(Io.Thrown), BadData(Str), TooLarge])
	get = |kv, key| get_io(kv, key, Err(MissingField), Body.default_max)

	get! : Kv(a), Str => Try(a, [NotFound, KvErr(Io.Thrown), BadData(Str), TooLarge])
	get! = |kv, key| Io.run!(kv.get(key))

	## `get`, and `default` for a key that is not there. The other errors stay.
	get_or : Kv(a), Str, a -> Io(a, [KvErr(Io.Thrown), BadData(Str), TooLarge])
	get_or = |kv, key, default| kv.get(key).recover(|e| match e {
		NotFound => Ok(default)
		KvErr(t) => Err(KvErr(t))
		BadData(m) => Err(BadData(m))
		TooLarge => Err(TooLarge)
	})

	get_or! : Kv(a), Str, a => Try(a, [KvErr(Io.Thrown), BadData(Str), TooLarge])
	get_or! = |kv, key, default| Io.run!(kv.get_or(key, default))

	## `get` that gives a missing key as `Ok(Err(NotFound))`, so the error type of the caller has no `NotFound`.
	find : Kv(a), Str -> Io(Try(a, [NotFound]), [KvErr(Io.Thrown), BadData(Str), TooLarge])
	find = |kv, key| kv.get(key).map(|v| Ok(v)).recover(|e| match e {
		NotFound => Ok(Err(NotFound))
		KvErr(t) => Err(KvErr(t))
		BadData(m) => Err(BadData(m))
		TooLarge => Err(TooLarge)
	})

	find! : Kv(a), Str => Try(Try(a, [NotFound]), [KvErr(Io.Thrown), BadData(Str), TooLarge])
	find! = |kv, key| Io.run!(kv.find(key))

	## `cache_ttl_ms`: 30 s or more (KV throws for less: `KvErr`). `max_bytes`: the limit of the value.
	get_with : Kv(a), Str, { cache_ttl_ms ?: U64, max_bytes ?: U64 } -> Io(a, [NotFound, KvErr(Io.Thrown), BadData(Str), TooLarge])
	get_with = |kv, key, opts| get_io(kv, key, opts.?cache_ttl_ms, opts.?max_bytes ?? Body.default_max)

	get_with! : Kv(a), Str, { cache_ttl_ms ?: U64, max_bytes ?: U64 } => Try(a, [NotFound, KvErr(Io.Thrown), BadData(Str), TooLarge])
	get_with! = |kv, key, opts| Io.run!(kv.get_with(key, opts))

	## `getWithMetadata`. The type of the metadata comes from the annotation at the call (MC7). A key with no metadata
	## has `Err(Missing)` in `metadata`. KV stores the metadata as JSON.
	get_with_metadata : Kv(a), Str -> Io({ value : a, metadata : Try(m, [Missing]) }, [NotFound, KvErr(Io.Thrown), BadData(Str), TooLarge]) where [m.Cbor.Readable(errs)]
	get_with_metadata = |kv, key| meta_io(kv, key, Err(MissingField), Body.default_max)

	get_with_metadata! : Kv(a), Str => Try({ value : a, metadata : Try(m, [Missing]) }, [NotFound, KvErr(Io.Thrown), BadData(Str), TooLarge]) where [m.Cbor.Readable(errs)]
	get_with_metadata! = |kv, key| Io.run!(kv.get_with_metadata(key))

	get_with_metadata_with : Kv(a), Str, { cache_ttl_ms ?: U64, max_bytes ?: U64 } -> Io({ value : a, metadata : Try(m, [Missing]) }, [NotFound, KvErr(Io.Thrown), BadData(Str), TooLarge]) where [m.Cbor.Readable(errs)]
	get_with_metadata_with = |kv, key, opts| meta_io(kv, key, opts.?cache_ttl_ms, opts.?max_bytes ?? Body.default_max)

	get_with_metadata_with! : Kv(a), Str, { cache_ttl_ms ?: U64, max_bytes ?: U64 } => Try({ value : a, metadata : Try(m, [Missing]) }, [NotFound, KvErr(Io.Thrown), BadData(Str), TooLarge]) where [m.Cbor.Readable(errs)]
	get_with_metadata_with! = |kv, key, opts| Io.run!(kv.get_with_metadata_with(key, opts))

	## `put(key, value)`: a value of 25 MiB or less (KV throws for more: `KvErr`).
	put : Kv(a), Str, a -> Io({}, [KvErr(Io.Thrown), BadData(Str)])
	put = |kv, key, v| put_io(kv, key, v, [])

	put! : Kv(a), Str, a => Try({}, [KvErr(Io.Thrown), BadData(Str)])
	put! = |kv, key, v| Io.run!(kv.put(key, v))

	## `ttl_ms`: a value under 60 s is raised to 60 s (KV throws for less). `expires_ms`: a time of the clock. `metadata`: made by
	## `Kv.Metadata.of(m)` (MC5), 1,024 bytes or less as JSON. It is not a type variable of the options: a call with no
	## `metadata` would leave the type of `m` open, and that does not compile ("type not determined", MODULES.md 5.2).
	put_with : Kv(a), Str, a, { ttl_ms ?: U64, expires_ms ?: U64, metadata ?: Kv.Metadata } -> Io({}, [KvErr(Io.Thrown), BadData(Str)])
	put_with = |kv, key, v, opts| {
		meta = match opts.?metadata {
			Ok(m) => [("metadata", Packed(m.cbor))]
			Err(_) => []
		}
		put_io(kv, key, v, expiry(opts.?ttl_ms, opts.?expires_ms).concat(meta))
	}

	put_with! : Kv(a), Str, a, { ttl_ms ?: U64, expires_ms ?: U64, metadata ?: Kv.Metadata } => Try({}, [KvErr(Io.Thrown), BadData(Str)])
	put_with! = |kv, key, v, opts| Io.run!(kv.put_with(key, v, opts))

	delete : Kv(a), Str -> Io({}, [KvErr(Io.Thrown)])
	delete = |kv, key| Io.new(
		[Get(Root("env"), kv.name), Call(Slot(0), "delete", [Lit(Text(key))])],
		|r| match r {
			Ok(_) => Ok({})
			Err(t) => Err(KvErr(t))
		},
	)

	delete! : Kv(a), Str => Try({}, [KvErr(Io.Thrown)])
	delete! = |kv, key| Io.run!(kv.delete(key))

	## `list`: the keys of one page (1,000 at most). The metadata of a key is CBOR, typed at the use (`Kv.Metadata.parse`).
	list : Kv(a), { prefix ?: Str, cursor ?: Str, limit ?: U32 } -> Io({ keys : List(Kv.Key), next : [More(Str), Done] }, [KvErr(Io.Thrown)])
	list = |kv, opts| {
		prefix = match opts.?prefix {
			Ok(p) => [("prefix", Text(p))]
			Err(_) => []
		}
		cursor = match opts.?cursor {
			Ok(c) => [("cursor", Text(c))]
			Err(_) => []
		}
		limit = match opts.?limit {
			Ok(n) => [("limit", Int(n.to_i64()))]
			Err(_) => []
		}
		Io.new(
			[
				Get(Root("env"), kv.name),
				Call(Slot(0), "list", [Lit(Obj(prefix.concat(cursor).concat(limit)))]),
				Call(Root("pf"), "kvList", [Slot(1)]),
			],
			|r| match r {
				Ok(v) => Ok(page_of(v))
				Err(t) => Err(KvErr(t))
			},
		)
	}

	list! : Kv(a), { prefix ?: Str, cursor ?: Str, limit ?: U32 } => Try({ keys : List(Kv.Key), next : [More(Str), Done] }, [KvErr(Io.Thrown)])
	list! = |kv, opts| Io.run!(kv.list(opts))

	## A key of `list!`.
	Key : { name : Str, expires_ms : [Never, At(U64)], metadata : Try(Kv.Metadata, [Missing]) }

	## The metadata of a key as CBOR. `of` writes it for `put_with!`, `parse` reads it typed at the use (MC7):
	## `(key.metadata ? |_| Missing).parse()`.
	Metadata :: { cbor : List(U8) }.{
		of : m -> Kv.Metadata where [m.Cbor.Writable]
		of = |m| Kv.Metadata.{ cbor: Cbor.encode(m) }

		parse : Kv.Metadata -> Try(m, [BadData(Str)]) where [m.Cbor.Readable(errs)]
		parse = |md| Cbor.parse(md.cbor).map_err(|e| BadData(Str.inspect(e)))
	}

	## One key as a value: `get!`, `set!` and `delete!` with no key argument (MODULES.md 9).
	cell : Kv(a), Str -> Kv.Cell(a)
	cell = |kv, key| Kv.Cell.{ kv, key }

	Cell(a) := { kv : Kv(a), key : Str }.{
		get : Kv.Cell(a) -> Io(a, [NotFound, KvErr(Io.Thrown), BadData(Str), TooLarge])
		get = |c| c.kv.get(c.key)

		get! : Kv.Cell(a) => Try(a, [NotFound, KvErr(Io.Thrown), BadData(Str), TooLarge])
		get! = |c| Io.run!(c.get())

		## `get` that gives a missing key as `Ok(Err(NotFound))`, so the error type of the caller has no `NotFound`.
		find : Kv.Cell(a) -> Io(Try(a, [NotFound]), [KvErr(Io.Thrown), BadData(Str), TooLarge])
		find = |c| c.kv.find(c.key)

		find! : Kv.Cell(a) => Try(Try(a, [NotFound]), [KvErr(Io.Thrown), BadData(Str), TooLarge])
		find! = |c| Io.run!(c.find())

		## The binding of the cell for the manifest, as `Kv.declare` gives it. Name one cell for each binding: the same
		## binding name twice in `bindings` is an error at load.
		declare : Kv.Cell(a) -> { name : Str, kind : Str, props : List((Str, Str)) }
		declare = |c| c.kv.declare()

		## `get`, and `default` for a key that is not there.
		get_or : Kv.Cell(a), a -> Io(a, [KvErr(Io.Thrown), BadData(Str), TooLarge])
		get_or = |c, default| c.kv.get_or(c.key, default)

		get_or! : Kv.Cell(a), a => Try(a, [KvErr(Io.Thrown), BadData(Str), TooLarge])
		get_or! = |c, default| Io.run!(c.get_or(default))

		set : Kv.Cell(a), a -> Io({}, [KvErr(Io.Thrown), BadData(Str)])
		set = |c, v| c.kv.put(c.key, v)

		set! : Kv.Cell(a), a => Try({}, [KvErr(Io.Thrown), BadData(Str)])
		set! = |c, v| Io.run!(c.set(v))

		## `ttl_ms`: a value under 60 s is raised to 60 s (KV throws for less). `expires_ms`: a time of the clock.
		set_with : Kv.Cell(a), a, { ttl_ms ?: U64, expires_ms ?: U64 } -> Io({}, [KvErr(Io.Thrown), BadData(Str)])
		set_with = |c, v, opts| put_io(c.kv, c.key, v, expiry(opts.?ttl_ms, opts.?expires_ms))

		set_with! : Kv.Cell(a), a, { ttl_ms ?: U64, expires_ms ?: U64 } => Try({}, [KvErr(Io.Thrown), BadData(Str)])
		set_with! = |c, v, opts| Io.run!(c.set_with(v, opts))

		delete : Kv.Cell(a) -> Io({}, [KvErr(Io.Thrown)])
		delete = |c| c.kv.delete(c.key)

		delete! : Kv.Cell(a) => Try({}, [KvErr(Io.Thrown)])
		delete! = |c| Io.run!(c.delete())
	}
}

## `env[name].get(key, { type: "stream", cacheTtl? })`, then the stream to `max` bytes (`pf.readMaybe`: `undefined` for a
## key that is not there).
get_io : Kv(a), Str, Try(U64, [MissingField]), U64 -> Io(a, [NotFound, KvErr(Io.Thrown), BadData(Str), TooLarge])
get_io = |kv, key, cache_ttl_ms, max| {
	read = kv.read
	Io.new(
		[
			Get(Root("env"), kv.name),
			Call(Slot(0), "get", [Lit(Text(key)), Lit(Obj(read_options(cache_ttl_ms)))]),
			Call(Root("pf"), "readMaybe", [Slot(1), Lit(Int(limit(max)))]),
		],
		|r| match r {
			Ok(Undefined) => Err(NotFound)
			Ok(Bytes(bytes)) => read(bytes).map_err(|text| BadData(text))
			Ok(other) => crash "Kv.get: readMaybe gave ${Str.inspect(other)}"
			Err(t) => Err(error(t)),
		},
	)
}

## `getWithMetadata(key, { type: "stream" })`, then `pf.kvMeta`: `{ value: bytes or undefined, metadata: Packed or undefined }`.
meta_io : Kv(a), Str, Try(U64, [MissingField]), U64 -> Io({ value : a, metadata : Try(m, [Missing]) }, [NotFound, KvErr(Io.Thrown), BadData(Str), TooLarge]) where [m.Cbor.Readable(errs)]
meta_io = |kv, key, cache_ttl_ms, max| {
	read = kv.read
	Io.new(
		[
			Get(Root("env"), kv.name),
			Call(Slot(0), "getWithMetadata", [Lit(Text(key)), Lit(Obj(read_options(cache_ttl_ms)))]),
			Call(Root("pf"), "kvMeta", [Slot(1), Lit(Int(limit(max)))]),
		],
		|r| match r {
			Ok(Obj(fields)) => match field(fields, "value") {
				Undefined => Err(NotFound)
				Bytes(bytes) => match read(bytes) {
					Ok(value) => match field(fields, "metadata") {
						Packed(cbor) => match Cbor.parse(cbor) {
							Ok(m) => Ok({ value, metadata: Ok(m) })
							Err(e) => Err(BadData("the metadata does not fit its type: ${Str.inspect(e)}"))
						}
						_ => Ok({ value, metadata: Err(Missing) })
					}
					Err(text) => Err(BadData(text))
				}
				other => crash "Kv.get_with_metadata: the value is ${Str.inspect(other)}"
			}
			Ok(other) => crash "Kv.get_with_metadata: kvMeta gave ${Str.inspect(other)}"
			Err(t) => Err(error(t)),
		},
	)
}

put_io : Kv(a), Str, a, List((Str, Js)) -> Io({}, [KvErr(Io.Thrown), BadData(Str)])
put_io = |kv, key, v, options| {
	write = kv.write
	match write(v) {
		Ok(js) => Io.new(
			[Get(Root("env"), kv.name), Call(Slot(0), "put", [Lit(Text(key)), Lit(js), Lit(Obj(options))])],
			|r| match r {
				Ok(_) => Ok({})
				Err(t) => Err(KvErr(t))
			},
		)
		# A value that does not encode: no program, so nothing is sent.
		Err(text) => Io.sync([], |_| Err(BadData("the value does not encode: ${text}")))
	}
}

## `expirationTtl` and `expiration` of `put`, in whole seconds.
expiry : Try(U64, [MissingField]), Try(U64, [MissingField]) -> List((Str, Js))
expiry = |ttl_ms, expires_ms| {
	ttl = match ttl_ms {
		Ok(ms) => [("expirationTtl", seconds(ms.max(min_ttl_ms)))]
		Err(_) => []
	}
	at = match expires_ms {
		Ok(ms) => [("expiration", seconds(ms))]
		Err(_) => []
	}
	ttl.concat(at)
}

read_options : Try(U64, [MissingField]) -> List((Str, Js))
read_options = |cache_ttl_ms| match cache_ttl_ms {
	Ok(ms) => [("type", Text("stream")), ("cacheTtl", seconds(ms))]
	Err(_) => [("type", Text("stream"))]
}

## KV throws for an `expirationTtl` under 60 s: `ttl_ms` is raised to this.
min_ttl_ms : U64
min_ttl_ms = 60_000

## MC10: KV takes whole seconds, so the module rounds up.
seconds : U64 -> Js
seconds = |ms| Int(Time.seconds_up(ms).to_i64_try() ?? I64.highest)

limit : U64 -> I64
limit = |n| n.to_i64_try() ?? I64.highest

## The limit of `pf.readMaybe` is `TooLarge` (MC11). Each other throw is `KvErr`.
error : Io.Thrown -> [KvErr(Io.Thrown), TooLarge]
error = |t| if t.name == "TooLarge" TooLarge else KvErr(t)

field : List((Str, Js)), Str -> Js
field = |fields, name| match fields.find_first(|(k, _)| k == name) {
	Ok((_, v)) => v
	Err(_) => Undefined
}

## The result of `pf.kvList`: `{ keys: [{ name, expiration, metadata }], cursor, complete }`. A shape that is not that is
## a platform bug: a crash.
page_of : Js -> { keys : List(Kv.Key), next : [More(Str), Done] }
page_of = |v| match v {
	Obj(fields) => {
		keys = match field(fields, "keys") {
			Arr(items) => items.map(key_of)
			other => crash "Kv.list: the keys are ${Str.inspect(other)}"
		}
		next = match field(fields, "cursor") {
			Text(c) => More(c)
			_ => Done
		}
		{ keys, next }
	}
	other => crash "Kv.list: kvList gave ${Str.inspect(other)}"
}

key_of : Js -> Kv.Key
key_of = |v| match v {
	Obj(fields) => {
		name = match field(fields, "name") {
			Text(s) => s
			other => crash "Kv.list: a key name is ${Str.inspect(other)}"
		}
		expires_ms = match field(fields, "expiration") {
			Int(s) => At(s.to_u64_try().map_ok(|n| n * 1000) ?? crash "Kv.list: a negative expiration")
			_ => Never
		}
		metadata = match field(fields, "metadata") {
			Packed(cbor) => Ok(Kv.Metadata.{ cbor })
			_ => Err(Missing)
		}
		{ name, expires_ms, metadata }
	}
	other => crash "Kv.list: a key is ${Str.inspect(other)}"
}

expect Kv.Metadata.of({ tag: "x" }).cbor == Cbor.encode({ tag: "x" })
expect error({ name: "TooLarge", message: "x" }) == TooLarge
expect error({ name: "Error", message: "x" }) == KvErr({ name: "Error", message: "x" })
expect seconds(1) == Int(1)
expect seconds(60_000) == Int(60)
expect read_options(Ok(30_001)) == [("type", Text("stream")), ("cacheTtl", Int(31))]
expect page_of(Obj([("keys", Arr([Obj([("name", Text("a")), ("expiration", Int(5))]), Obj([("name", Text("b"))])])), ("cursor", Text("c1"))])).next == More("c1")
