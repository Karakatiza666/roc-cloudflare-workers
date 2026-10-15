## Backing `{ s : Str }`, bare: W has no encoder_for, so the encode must not compile.
W :: { s : Str }

main! = |_args| {
	echo!(Json.to_str(W.({ s: "x" })))
	Ok({})
}
