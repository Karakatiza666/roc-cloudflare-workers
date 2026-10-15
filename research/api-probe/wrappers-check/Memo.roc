## Can `Memo` (API.md 7.1) hold an effectful `load!` and a codec, and be called as `jwks.get!()`?
## The pin table is left out: `get!` always loads, then sends the value through the codec.
Memo(a, e) := { name : Str, max_age_ms : U64, load! : {} => Try(a, e), codec : Codec(a) }.{
	new : Str, { max_age_ms : U64, load! : {} => Try(a, e), codec : Codec(a) } -> Memo(a, e)
	new = |name, o| { name, max_age_ms: o.max_age_ms, load!: o.load!, codec: o.codec }

	get! : Memo(a, e) => Try(a, e)
	get! = |m| {
		load! = m.load!
		v = load!({})?
		js = (m.codec.to_js)(v)
		match (m.codec.from_js)(js) {
			Ok(back) => Ok(back)
			Err(_) => load!({})
		}
	}
}

Codec(a) : { to_js : a -> Str, from_js : Str -> Try(a, [BadJs(Str)]) }
