## Q7, option E: the domain tags flat, the infrastructure in `Infra(...)` with `? Infra` at each platform call.
## Does a closed sub-union of a function result widen into `Infra(Infra)`?
Thrown : { name : Str, message : Str }

Infra : [StorageErr(Thrown), SqlErr(Thrown), BadData(Str), TooLarge]

cell_set : U64 -> Try({}, [StorageErr(Thrown)])
cell_set = |n| if (n == 1) Err(StorageErr({ name: "Error", message: "disk" })) else Ok({})

sql : U64 -> Try(U64, [SqlErr(Thrown), BadData(Str), TooLarge])
sql = |n| if (n == 2) Err(SqlErr({ name: "Error", message: "no table" })) else Ok(n)

handler : U64 -> Try(U64, [NotOpen, Infra(Infra)])
handler = |n| {
	if n == 0 {
		return Err(NotOpen)
	}
	cell_set(n) ? Infra
	w = sql(n) ? Infra
	Ok(w)
}

main! = |_args| {
	for n in [0, 1, 2, 3] {
		echo!("${Str.inspect(handler(n))}\n")
	}
	Ok({})
}
