## Q8, option G: each platform function gives its infrastructure error nested, `Infra(KvErr(..))`.
## G1a: the payload is precise and closed. G1b: precise with an open row. G2: the whole closed `Infra`.
Thrown : { name : Str, message : Str }

Infra : [StorageErr(Thrown), SqlErr(Thrown), KvErr(Thrown), BadData(Str), TooLarge]

t : Thrown
t = { name: "Error", message: "x" }

# ---- G1a: precise, closed payload ----
kv_a : U64 -> Try(U64, [NotFound, Infra([KvErr(Thrown), BadData(Str), TooLarge])])
kv_a = |n| if (n == 0) Err(NotFound) else if (n == 1) Err(Infra(KvErr(t))) else Ok(n)

sql_a : U64 -> Try(U64, [Infra([SqlErr(Thrown), BadData(Str)])])
sql_a = |n| if (n == 2) Err(Infra(SqlErr(t))) else Ok(n)

## (1) `?` of two functions into the closed handler error of an Rpc.
handler_a : U64 -> Try(U64, [NotOpen, Infra(Infra)])
handler_a = |n| {
	v = kv_a(n) ? |e| match e {
		NotFound => NotOpen
		Infra(i) => Infra(i)
	}
	w = sql_a(v)?
	Ok(w)
}

## (2) A helper with no annotation, `?` of both: one payload row.
helper_a = |n| {
	v = kv_a(n)?
	sql_a(v)
}

## (3) Code outside Rpc: an exhaustive match with no `_`.
plain_a : U64 -> Str
plain_a = |n| match kv_a(n) {
	Ok(_) => "ok"
	Err(NotFound) => "404"
	Err(Infra(KvErr(_))) => "503 kv"
	Err(Infra(BadData(_))) | Err(Infra(TooLarge)) => "500 data"
}

# ---- G1b: precise payload, open row ----
kv_b : U64 -> Try(U64, [NotFound, Infra([KvErr(Thrown), BadData(Str), TooLarge, ..i])])
kv_b = |n| if (n == 0) Err(NotFound) else if (n == 1) Err(Infra(KvErr(t))) else Ok(n)

sql_b : U64 -> Try(U64, [Infra([SqlErr(Thrown), BadData(Str), ..i])])
sql_b = |n| if (n == 2) Err(Infra(SqlErr(t))) else Ok(n)

handler_b : U64 -> Try(U64, [NotOpen, Infra(Infra)])
handler_b = |n| {
	v = match kv_b(n) {
		Ok(x) => x
		Err(NotFound) => return Err(NotOpen)
		Err(Infra(i)) => return Err(Infra(i))
	}
	w = sql_b(v)?
	Ok(w)
}

plain_b : U64 -> Str
plain_b = |n| match kv_b(n) {
	Ok(_) => "ok"
	Err(NotFound) => "404"
	Err(Infra(KvErr(_))) => "503 kv"
	Err(Infra(BadData(_))) | Err(Infra(TooLarge)) => "500 data"
}

# ---- G2: the whole closed Infra in each function ----
kv_c : U64 -> Try(U64, [NotFound, Infra(Infra)])
kv_c = |n| if (n == 0) Err(NotFound) else if (n == 1) Err(Infra(KvErr(t))) else Ok(n)

plain_c : U64 -> Str
plain_c = |n| match kv_c(n) {
	Ok(_) => "ok"
	Err(NotFound) => "404"
	Err(Infra(KvErr(_))) => "503 kv"
	Err(Infra(_)) => "500 other (the type says SqlErr can come)"
}

main! = |_args| {
	for n in [0, 1, 2, 3] {
		echo!("${Str.inspect(handler_a(n))} ${Str.inspect(helper_a(n))} ${plain_a(n)} | ${Str.inspect(handler_b(n))} ${plain_b(n)} | ${plain_c(n)} ${Json.to_str(handler_a(n) ?? 0)}\n")
	}
	Ok({})
}
