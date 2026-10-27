import Lib

f = |b| {
	Lib.c?
	Lib.g(b)?
	Ok({})
}

main! = |_args| {
	echo!(Str.inspect(f(Bool.True)))
	Ok({})
}
