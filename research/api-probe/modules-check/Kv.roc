import Io
import Body
import Cbor

## A KV namespace of values of one type. The declaration picks the format: `Kv.json`, `Kv.text`.
Kv(a) :: { name : Str, write : a -> Str, read : Str -> Try(a, Str) }.{
	json : Str -> Kv(a) where [a.Json.Encodable([]), a.Json.Parseable([InvalidJson(Str), ..errs])]
	json = |name| Kv.{ name, write: |v| Json.to_str(v), read: |t| Json.parse(t).map_err(|e| Str.inspect(e)) }

	text : Str -> Kv(Str)
	text = |name| Kv.{ name, write: |s| s, read: |s| Ok(s) }

	get : Kv(a), Str -> Io(a, [NotFound, KvErr(Io.Thrown), BadData(Str), TooLarge])
	get = |kv, key| {
		Kv.{ name, read, .. } = kv
		Io.new(["kv.get", name, key, Io.max(Body.default_max)], |r| match r {
			Ok(bytes) if bytes == Io.null => Err(NotFound)
			# The stored text, as JS reads it with `get(key, "text")`. `Kv.json` parses it in Roc,
			# so an integer above 2^53 stays exact.
			Ok(bytes) => match Io.decode(bytes) {
				Ok(stored) => read(stored).map_err(|m| BadData(m))
				Err(BadData(m)) => Err(BadData(m))
			}
			Err(t) => Err(err(t))
		})
	}

	get! : Kv(a), Str => Try(a, [NotFound, KvErr(Io.Thrown), BadData(Str), TooLarge])
	get! = |kv, key| Io.run!(get(kv, key))

	## `getWithMetadata`. The type of the metadata comes from the annotation at the call (MC7).
	get_with_metadata! : Kv(a), Str => Try({ value : a, metadata : Try(m, [Missing]) }, [NotFound, KvErr(Io.Thrown), BadData(Str), TooLarge])
		where [m.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	get_with_metadata! = |kv, key| {
		Kv.{ name, read, .. } = kv
		got : Try({ value : Str, metadata : List(U8) }, _)
		got = Io.run!(Io.new(["kv.get_meta", name, key, Io.max(Body.default_max)], |r| match r {
			Ok(bytes) if bytes == Io.null => Err(NotFound)
			Ok(bytes) => Io.decode(bytes)
			Err(t) => Err(err(t))
		}))
		{ value, metadata } = got?
		v = read(value).map_err(|m| BadData(m))?
		meta = if metadata.is_empty() Err(Missing) else Ok(Io.decode(metadata)?)
		Ok({ value: v, metadata: meta })
	}

	put_with : Kv(a), Str, a, { ttl_ms ?: U64, expires_ms ?: U64, metadata ?: m } -> Io({}, [KvErr(Io.Thrown)]) where [m.Cbor.Encodable([])]
	put_with = |kv, key, v, opts| {
		Kv.{ name, write, .. } = kv
		# MC10: KV takes whole seconds, so the module rounds up.
		ttl = opts.?ttl_ms.map_ok(|n| seconds(n).to_str()) ?? "none"
		expires = opts.?expires_ms.map_ok(|n| seconds(n).to_str()) ?? "none"
		meta = opts.?metadata.map_ok(|m| Io.arg(m)) ?? "none"
		Io.new(["kv.put", name, key, write(v), ttl, expires, meta], |r| r.map_ok(|_| {}).map_err(|t| KvErr(t)))
	}

	put_with! : Kv(a), Str, a, { ttl_ms ?: U64, expires_ms ?: U64, metadata ?: m } => Try({}, [KvErr(Io.Thrown)]) where [m.Cbor.Encodable([])]
	put_with! = |kv, key, v, opts| Io.run!(put_with(kv, key, v, opts))

	put! : Kv(a), Str, a => Try({}, [KvErr(Io.Thrown)])
	put! = |kv, key, v| Io.run!(put_with(kv, key, v, {}))

	## The keys, with their metadata as CBOR: `list!` cannot take a type (MODULES.md 5.2).
	list! : Kv(a), { prefix ?: Str, cursor ?: Str, limit ?: U32 } => Try({ keys : List(Kv.Key), next : [More(Str), Done] }, [KvErr(Io.Thrown)])
	list! = |kv, opts| {
		Kv.{ name, .. } = kv
		got : { keys : List({ name : Str, expires_ms : U64, metadata : List(U8) }), cursor : Str }
		got = Io.run!(Io.tree(["kv.list", name, opts.?prefix ?? ""], |t| KvErr(t)))?
		keys = got.keys.map(|k| {
			name: k.name,
			expires_ms: if k.expires_ms == 0 Never else At(k.expires_ms),
			metadata: if k.metadata.is_empty() Err(Missing) else Ok(Kv.Metadata.{ cbor: k.metadata }),
		})
		Ok({ keys, next: if got.cursor == "" Done else More(got.cursor) })
	}

	Key : { name : Str, expires_ms : [Never, At(U64)], metadata : Try(Kv.Metadata, [Missing]) }

	## Metadata as CBOR, typed at the use (MC7): `key.metadata?.parse()`.
	Metadata :: { cbor : List(U8) }.{
		parse : Kv.Metadata -> Try(m, [BadData(Str)]) where [m.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		parse = |md| {
			Kv.Metadata.{ cbor } = md
			Io.decode(cbor)
		}
	}

	## A declaration of one key: the `localStorage` wrapper.
	cell : Kv(a), Str -> Kv.Cell(a)
	cell = |kv, key| { kv, key }

	Cell(a) := { kv : Kv(a), key : Str }.{
		get! : Kv.Cell(a) => Try(a, [NotFound, KvErr(Io.Thrown), BadData(Str), TooLarge])
		get! = |c| c.kv.get!(c.key)

		set! : Kv.Cell(a), a => Try({}, [KvErr(Io.Thrown)])
		set! = |c, v| c.kv.put!(c.key, v)
	}
}

err : Io.Thrown -> [KvErr(Io.Thrown), TooLarge]
err = |t| if Io.too_large(t) TooLarge else KvErr(t)

## Milliseconds to whole seconds, rounded up (MC10).
seconds : U64 -> U64
seconds = |ms| (ms + 999) // 1000
