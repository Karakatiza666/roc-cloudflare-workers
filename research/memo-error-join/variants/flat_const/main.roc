import Lib

f : Bool -> Try({}, [A, B])
f = |b| {
	Lib.c?
	if b Err(B) else Ok({})
}

main! = |_args| {
	echo!(Str.inspect(f(Bool.True)))
	Ok({})
}
