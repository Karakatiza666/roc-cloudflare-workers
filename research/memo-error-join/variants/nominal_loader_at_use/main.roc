import Lib

load = || Err(Inner(A))

f : Bool -> Try({}, [Inner([A, B])])
f = |b| {
	Lib.c.get(load)?
	if b Err(Inner(B)) else Ok({})
}

main! = |_args| {
	echo!(Str.inspect(f(Bool.True)))
	Ok({})
}
