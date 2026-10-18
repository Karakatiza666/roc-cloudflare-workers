## Probe (step 8h): `{ a }` with one field is a block, not a record. `{ a, }` and `{ a: a }` are records. `roc research/e1-errors/one_field.roc` prints "5 5".
f : { a ?: U64, b ?: Str } -> U64
f = |r| r.?a ?? 0

main! = |_args| {
	a = 5.U64
	x = f({ a, })
	y = f({ a: a })
	echo!("${x.to_str()} ${y.to_str()}")
	Ok({})
}
