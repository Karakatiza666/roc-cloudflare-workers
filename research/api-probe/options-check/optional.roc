## MODULES.md 5.2: an optional field with a type variable that a `where` clause names (`metadata ?: m`) compiles when the caller leaves it out, and `.?field` reads an optional field.
put_with : Str, { ttl_ms ?: U64, metadata ?: m } -> Str where [m.Json.Encodable([])]
put_with = |k, opts| {
	meta = match opts.?metadata {
		Ok(m) => Json.to_str(m)
		Err(_) => "none"
	}
	"${k} ${meta}"
}

Http : { content_type ?: Str, cache_control ?: Str }

ct : Http -> Str
ct = |h| h.?content_type ?? "none"

main! = |_args| {
	echo!(put_with("a", { ttl_ms: 5 }))
	echo!(put_with("b", { metadata: { v: 1.U64 } }))
	h : Http
	h = { cache_control: "x" }
	echo!(ct(h))
	echo!(ct({ content_type: "text/plain" }))
	Ok({})
}
