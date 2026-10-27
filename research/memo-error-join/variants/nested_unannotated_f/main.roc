import Lib

f = |b| {
	Lib.c?
	if b Err(Inner(B)) else Ok({})
}

main! = |_args| {
	echo!(Str.inspect(f(Bool.True)))
	Ok({})
}
