## Q1, option B: an alias with a row variable, `Infra(e) : [..., ..e]`, given a closed union.
## Does `?` of platform-shaped calls fit with no per-call code? Does the derived encoder take it?
Thrown : { name : Str, message : Str }

Infra(e) : [StorageErr(Thrown), SqlErr(Thrown), BadData(Str), TooLarge, ..e]

RoomErr : Infra([NotOpen, AlreadyOpen, StillOpen])

cell_get : U64 -> Try(U64, [NotFound, BadData(Str), StorageErr(Thrown)])
cell_get = |n| if (n == 0) Err(NotFound) else if (n == 1) Err(StorageErr({ name: "Error", message: "disk" })) else Ok(n)

sql : U64 -> Try(U64, [SqlErr(Thrown), BadData(Str), TooLarge])
sql = |n| if (n == 2) Err(SqlErr({ name: "Error", message: "no table" })) else Ok(n)

handler : U64 -> Try(U64, RoomErr)
handler = |n| {
	v = match cell_get(n) {
		Ok(x) => x
		Err(NotFound) => return Err(NotOpen)
		Err(BadData(s)) => return Err(BadData(s))
		Err(StorageErr(t)) => return Err(StorageErr(t))
	}
	w = sql(v)?
	Ok(w)
}

# The caller: tags of the domain and of the infrastructure, all typed.
show : Try(U64, RoomErr) -> Str
show = |r| match r {
	Ok(v) => "ok ${v.to_str()}"
	Err(NotOpen) => "not open"
	Err(AlreadyOpen) | Err(StillOpen) => "state"
	Err(StorageErr(t)) => "storage: ${t.message}"
	Err(SqlErr(t)) => "sql: ${t.message}"
	Err(BadData(_)) | Err(TooLarge) => "data"
}

enc : RoomErr -> Str
enc = |e| Json.to_str(e)

main! = |_args| {
	for n in [0, 1, 2, 3] {
		r = handler(n)
		echo!(
			"${show(r)} ${
				match r {
					Ok(_) => ""
					Err(e) => enc(e)
				}
			}\n",
		)
	}
	Ok({})
}
