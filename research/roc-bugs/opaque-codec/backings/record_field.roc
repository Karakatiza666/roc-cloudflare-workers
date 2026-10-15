## Backing `{ s : Str }`, field: W has no encoder_for, so the encode must not compile.
W :: { s : Str }

main! = |_args| {
	echo!(Json.to_str({ v: W.({ s: "x" }) }))
	Ok({})
}
