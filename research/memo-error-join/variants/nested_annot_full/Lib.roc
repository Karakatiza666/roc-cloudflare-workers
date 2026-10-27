Lib := [].{
	Err : [Inner([A, B])]
	c : Try({}, Lib.Err)
	c = Err(Inner(A))
	g : Bool -> Try({}, [Inner([B])])
	g = |b| if b Err(Inner(B)) else Ok({})
}
