import Lib

main! = |args| {
	n = args.len().to_u64()
	echo!(Str.inspect(Lib.table.append(n).len() + Lib.table.get(n).ok_or(0)))
	Ok({})
}
