# Repro: one List.sort_with of a record list gives about 100 KB or more of code.
Row : { a : Str, b : Str, c : Str, d : Str, e : Str, f : Str, n : U64, k : U64 }

main! = |args| {
	rows : List(Row)
	rows = args.map(|s| { a: s, b: s, c: s, d: s, e: s, f: s, n: s.count_utf8_bytes(), k: 1 })
	sorted = rows.sort_with(|x, y| x.n.order_relative_to(y.n))
	echo!(Str.inspect(sorted.len()))
	Ok({})
}
