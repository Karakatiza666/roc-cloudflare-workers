import Io

## A KV namespace of values of one type. The declaration picks the format: `Kv.json`, `Kv.text`.
Kv(a) :: { name : Str, write : a -> Str, read : Str -> Try(a, Str) }.{
	json : Str -> Kv(a) where [a.Json.Encodable([]), a.Json.Parseable([InvalidJson(Str), ..errs])]
	json = |name| Kv.{ name, write: |v| Json.to_str(v), read: |t| Json.parse(t).map_err(|e| Str.inspect(e)) }

	text : Str -> Kv(Str)
	text = |name| Kv.{ name, write: |s| s, read: |s| Ok(s) }

	get : Kv(a), Str -> Io(a, [NotFound, KvErr(Io.Thrown), BadData(Str)])
	get = |kv, key| {
		Kv.{ name, read, .. } = kv
		Io.new(["kv.get", name, key], |r| match r {
			Ok(bytes) if bytes == Io.null => Err(NotFound)
			# The stored text, as JS reads it with `get(key, "text")`. `Kv.json` parses it in Roc,
			# so an integer above 2^53 stays exact.
			Ok(bytes) => match Io.decode(bytes) {
				Ok(stored) => read(stored).map_err(|m| BadData(m))
				Err(BadData(m)) => Err(BadData(m))
			}
			Err(t) => Err(KvErr(t))
		})
	}

	get! : Kv(a), Str => Try(a, [NotFound, KvErr(Io.Thrown), BadData(Str)])
	get! = |kv, key| Io.run!(get(kv, key))

	put_with : Kv(a), Str, a, { ttl_ms ?: U64 } -> Io({}, [KvErr(Io.Thrown)])
	put_with = |kv, key, v, opts| {
		Kv.{ name, write, .. } = kv
		ttl = opts.?ttl_ms.map_ok(|n| n.to_str()) ?? "none"
		Io.new(["kv.put", name, key, write(v), ttl], |r| r.map_ok(|_| {}).map_err(|t| KvErr(t)))
	}

	put_with! : Kv(a), Str, a, { ttl_ms ?: U64 } => Try({}, [KvErr(Io.Thrown)])
	put_with! = |kv, key, v, opts| Io.run!(put_with(kv, key, v, opts))

	put! : Kv(a), Str, a => Try({}, [KvErr(Io.Thrown)])
	put! = |kv, key, v| Io.run!(put_with(kv, key, v, {}))

	## A declaration of one key: the `localStorage` wrapper.
	cell : Kv(a), Str -> Kv.Cell(a)
	cell = |kv, key| { kv, key }

	Cell(a) := { kv : Kv(a), key : Str }.{
		get! : Kv.Cell(a) => Try(a, [NotFound, KvErr(Io.Thrown), BadData(Str)])
		get! = |c| c.kv.get!(c.key)

		set! : Kv.Cell(a), a => Try({}, [KvErr(Io.Thrown)])
		set! = |c, v| c.kv.put!(c.key, v)
	}
}
