## Bug: a record field of a nominal (`:=`, not opaque) type over Str, with no opt in. It compiles.
Name := Str.{
	from_str : Str -> Name
	from_str = |s| Name.(s)
}

main! = |_args| {
	echo!(Json.to_str({ name: Name.from_str("x") }))
	Ok({})
}
