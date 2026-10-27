Lib := [].{
	Holder(a) := { name : Str, value : a }.{
		get : Lib.Holder(a), (() -> Try(a, e)) -> Try(a, e)
		get = |_m, load| load()
	}
	c : Lib.Holder({})
	c = { name: "c", value: {} }
}
