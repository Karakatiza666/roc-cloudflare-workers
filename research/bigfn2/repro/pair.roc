main! = |args| {
	rows : List((I64, U64))
	rows = args.map_with_index(|s, i| (s.count_utf8_bytes().to_i64_wrap(), i))
	sorted = rows.sort_with(|x, y| x.0.order_relative_to(y.0))
	echo!(Str.inspect(sorted.len()))
	Ok({})
}
