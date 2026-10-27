import Lib

f : Bool -> Try({}, [Inner([A, B])])
f = |b| {
	Lib.c()?
	if b Err(Inner(B)) else Ok({})
}

main! = |_args| {
	echo!(Str.inspect(f(Bool.True)))
	Ok({})
}
