import Io
import Cbor

## A value kept in the isolate across requests: a cache, never state (API.md AQ3).
## The pin table keeps the CBOR bytes of the value: JS never parses them.
## The pin table is a fake here: `get!` always misses, so it always loads.
Memo(a, e) := { name : Str, max_age_ms : U64, load! : {} => Try(a, e), write : a -> List(U8), read : List(U8) -> Try(a, Str) }.{
	new : Str, { max_age_ms : U64, load! : {} => Try(a, e) } -> Memo(a, e)
		where [a.Cbor.Encodable([]), a.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	new = |name, o| { name, max_age_ms: o.max_age_ms, load!: o.load!, write: |v| Cbor.encode(v), read: |b| Cbor.parse(b).map_err(|e| Str.inspect(e)) }

	get! : Memo(a, e) => Try(a, e)
	get! = |m| {
		read = m.read
		write = m.write
		load! = m.load!
		pinned = Io.run!(Io.new(["memo.pinned", m.name], |r| r))
		match pinned {
			Ok(bytes) if bytes != Io.null => match read(bytes) {
				Ok(v) => Ok(v)
				Err(_) => load!({})
			}
			_ => {
				v = load!({})?
				_ = Io.run!(Io.new(["memo.pin", m.name, Str.inspect(write(v)), m.max_age_ms.to_str()], |r| r))
				Ok(v)
			}
		}
	}
}
