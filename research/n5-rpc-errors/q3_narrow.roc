## Q3, option D: can a match take the infrastructure tags out of a flat union and give the rest as `..e`?
## Then `on` could split a flat handler error, and the handler would write `Err(NotOpen)` with no `Fail`.
Thrown : { name : Str, message : Str }

Infra : [StorageErr(Thrown), TooLarge]

split : [StorageErr(Thrown), TooLarge, ..e] -> [Infra(Infra), Remote([..e])]
split = |x| match x {
	StorageErr(t) => Infra(StorageErr(t))
	TooLarge => Infra(TooLarge)
	other => Remote(other)
}

main! = |_args| {
	v : [StorageErr(Thrown), TooLarge, NotOpen]
	v = NotOpen
	echo!(Str.inspect(split(v)))
	Ok({})
}
