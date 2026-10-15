## MODULES.md 5.2: must NOT compile ("type not determined"). A parsed type variable that only a `where` clause names, with no annotation at the call. So `Kv.Key` keeps its metadata as CBOR.
Key(m) : { name : Str, metadata : Try(m, [Missing]) }

list : Str -> List(Key(m)) where [m.Json.Parseable([InvalidJson(Str), MissingRequiredField(Str)])]
list = |text| {
	meta : Try(m, _)
	meta = Json.parse(text)
	[{ name: "a", metadata: meta.map_err(|_| Missing) }]
}

main! = |_args| {
	keys = list("{\"v\":1}")
	for k in keys {
		echo!(k.name)
	}
	typed : List(Key({ v : U64 }))
	typed = list("{\"v\":1}")
	for k in typed {
		echo!(Str.inspect(k.metadata))
	}
	Ok({})
}
