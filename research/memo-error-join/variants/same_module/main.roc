c : Try({}, _)
c = Err(Inner(A))

f : Bool -> Try({}, [Inner([A, B])])
f = |b| {
	c?
	if b Err(Inner(B)) else Ok({})
}

main! = |_args| {
	echo!(Str.inspect(f(Bool.True)))
	Ok({})
}
