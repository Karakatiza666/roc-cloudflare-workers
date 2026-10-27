Lib := [].{
	c : Try({}, [Inner([A])])
	c = Err(Inner(A))
}
