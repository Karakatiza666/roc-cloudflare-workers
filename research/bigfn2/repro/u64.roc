main! = |args| {
	rows : List(U64)
	rows = args.map(|s| s.count_utf8_bytes())
	sorted = rows.sort_with(|x, y| x.order_relative_to(y))
	echo!(Str.inspect(sorted.len()))
	Ok({})
}
