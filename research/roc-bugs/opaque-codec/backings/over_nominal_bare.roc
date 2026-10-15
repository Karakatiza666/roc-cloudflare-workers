## Backing: a nominal type that opts in (Inner), bare. W has no encoder_for, so it must not compile.
Inner := { s : Str }.{
	encoder_for : _
}

W :: Inner

main! = |_args| {
	echo!(Json.to_str(W.(Inner.{ s: "x" })))
	Ok({})
}
