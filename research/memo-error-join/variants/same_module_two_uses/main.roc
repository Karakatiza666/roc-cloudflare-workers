c : Try({}, _)
c = Err(Inner(A))

f : Bool -> Try({}, [Inner([A, B])])
f = |b| {
	c?
	if b Err(Inner(B)) else Ok({})
}

g : Bool -> Try({}, [Inner([A, C])])
g = |b| {
	c?
	if b Err(Inner(C)) else Ok({})
}

main! = |_args| {
	echo!(Str.inspect(f(Bool.True)))
	echo!(Str.inspect(g(Bool.True)))
	Ok({})
}
