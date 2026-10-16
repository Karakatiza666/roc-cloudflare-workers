## A value kept in the isolate across requests (MODULES.md 9): a cache, never state. The pin table of the shim (API.md
## RS2) keeps the value as CBOR bytes, so JS never parses it, and a later request reads it with one `call!` (no wait)
## and `Cbor.parse`. The first `get!` in an isolate, and the first after `max_age_ms`, runs `load!`.
import Io
import Js
import cbor.Cbor

Memo(a, e) := { name : Str, max_age_ms : U64, load! : {} => Try(a, e), write : a -> List(U8), read : List(U8) -> Try(a, Str) }.{
	## A constant (WR1): it does nothing until `get!`. `load!` needs a type annotation (MODULES.md 15).
	new : Str, { max_age_ms : U64, load! : {} => Try(a, e) } -> Memo(a, e) where [a.Cbor.Encodable([]), a.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	new = |name, opts| Memo.{
		name,
		max_age_ms: opts.max_age_ms,
		load!: opts.load!,
		write: |v| Cbor.encode(v),
		read: |bytes| Cbor.parse(bytes).map_err(|e| Str.inspect(e)),
	}

	## The pinned value, else `load!` and a pin of its value. A pinned value that does not parse (an older type of the
	## same name) loads again. A pin that fails (a full pin table) does not fail `get!`: the value is a cache.
	get! : Memo(a, e) => Try(a, e)
	get! = |m| {
		read = m.read
		pinned = match Io.call!([Call(Root("pf"), "pinned", [Lit(Text(m.name))])]) {
			Ok(Bytes(bytes)) => read(bytes)
			_ => Err("not pinned")
		}
		match pinned {
			Ok(v) => Ok(v)
			Err(_) => {
				load! = m.load!
				write = m.write
				v = load!({})?
				age = m.max_age_ms.to_i64_try() ?? I64.highest
				_ = Io.call!([Call(Root("pf"), "pin", [Lit(Text(m.name)), Lit(Bytes(write(v))), Lit(Int(age))])])
				Ok(v)
			}
		}
	}

	## Drop the pinned value, so the next `get!` loads again.
	clear! : Memo(a, e) => {}
	clear! = |m| {
		_ = Io.call!([Call(Root("pf"), "unpin", [Lit(Text(m.name))])])
		{}
	}
}
