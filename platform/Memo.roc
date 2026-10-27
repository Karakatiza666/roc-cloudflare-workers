## A value kept in the isolate across requests (MODULES.md 9): a cache, never state. The pin table of the shim (API.md
## RS2) keeps the value as CBOR bytes, so JS never parses it, and a later request reads it with one `call!` (no wait)
## and `Cbor.parse`. The first `get!` in an isolate, and the first after `max_age_ms`, runs the loader of the call.
## A `Memo` has no error type: the loader is an argument of `get!`, so a `Memo` constant joins with the errors of
## each caller (MODULES.md 9, "A constant and its error type").
## Typed data: the format, what a JS peer sees, and what survives a round trip are in MODULES.md 1, "Formats of typed data".
import Io
import Js
import cbor.Cbor

Memo(a) := { name : Str, max_age_ms : U64, write : a -> List(U8), read : List(U8) -> Try(a, Str) }.{

	## A constant (WR1): it does nothing until `get!`.
	new : Str, { max_age_ms : U64 } -> Memo(a) where [a.Cbor.Writable, a.Cbor.Readable(errs)]
	new = |name, opts| Memo.{
		name,
		max_age_ms: opts.max_age_ms,
		write: |v| Cbor.encode(v),
		read: |bytes| Cbor.parse(bytes).map_err(|e| Str.inspect(e)),
	}

	## The pinned value, else `load!` and a pin of its value. The error type is the one of `load!`. A pinned value that
	## does not parse (an older type of the same name) loads again. A pin that fails (a full pin table) does not fail
	## `get!`: the value is a cache. Give the same `load!` at each call of one `Memo`: the first call in the isolate pins.
	## `load!` needs a type annotation (MODULES.md 15).
	get! : Memo(a), (() => Try(a, e)) => Try(a, e)
	get! = |m, load!| {
		read = m.read
		pinned = match Js.call!([Call(Root("pf"), "pinned", [Lit(Text(m.name))])]) {
			Ok(Bytes(bytes)) => read(bytes)
			_ => Err("not pinned")
		}
		match pinned {
			Ok(v) => Ok(v)
			Err(_) => {
				write = m.write
				v = load!()?
				age = m.max_age_ms.to_i64_try() ?? I64.highest
				_ = Js.call!([Call(Root("pf"), "pin", [Lit(Text(m.name)), Lit(Bytes(write(v))), Lit(Int(age))])])
				Ok(v)
			}
		}
	}

	## Drop the pinned value, so the next `get!` loads again.
	clear! : Memo(a) => {}
	clear! = |m| {
		_ = Js.call!([Call(Root("pf"), "unpin", [Lit(Text(m.name))])])
		{}
	}
}
