## Bug, in one file: an opaque type over `Str` has no `encoder_for` (no opt in), but in a record
## field the JSON encoder writes its hidden text. Expected: "missing method encoder_for".
## Got: it compiles and prints {"token":"hunter2"}.
Local :: Str.{
	from_str : Str -> Local
	from_str = |s| Local.(s)
}

main! = |_args| {
	echo!(Json.to_str({ token: Local.from_str("hunter2") }))
	Ok({})
}
