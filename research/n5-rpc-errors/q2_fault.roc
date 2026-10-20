## Q2, option C: the handler error is `Fault(err)`: the domain tags in `Fail`, the infrastructure tags flat.
## `?` of platform-shaped calls fits with no per-call code. A generic `on` (a returned lambda) encodes it
## (the risk of roc-lang/roc#12482). The caller splits it into `Remote(err)` and `Infra(Infra)`.
Thrown : { name : Str, message : Str }

Infra : [StorageErr(Thrown), SqlErr(Thrown), BadData(Str), TooLarge]

Fault(err) : [Fail(err), StorageErr(Thrown), SqlErr(Thrown), BadData(Str), TooLarge]

RoomErr : [NotOpen, AlreadyOpen, StillOpen]

cell_get : U64 -> Try(U64, [NotFound, BadData(Str), StorageErr(Thrown)])
cell_get = |n| if (n == 0) Err(NotFound) else if (n == 1) Err(StorageErr({ name: "Error", message: "disk" })) else Ok(n)

sql : U64 -> Try(U64, [SqlErr(Thrown), BadData(Str), TooLarge])
sql = |n| if (n == 2) Err(SqlErr({ name: "Error", message: "no table" })) else if (n == 4) Err(TooLarge) else Ok(n)

## A domain check: its own closed union. `? Fail` puts it in the fault.
check : U64 -> Try({}, [StillOpen])
check = |n| if (n == 5) Err(StillOpen) else Ok({})

handler : U64 -> Try(U64, Fault(RoomErr))
handler = |n| {
	v = match cell_get(n) {
		Ok(x) => x
		Err(NotFound) => return Err(Fail(NotOpen))
		Err(BadData(s)) => return Err(BadData(s))
		Err(StorageErr(t)) => return Err(StorageErr(t))
	}
	check(v) ? Fail
	w = sql(v)?
	Ok(w)
}

## The split of a fault: the domain error, or the closed infrastructure union. Pure, written once in the platform.
domain_or_infra : Fault(err) -> Try(err, Infra)
domain_or_infra = |f| match f {
	Fail(e) => Ok(e)
	StorageErr(t) => Err(StorageErr(t))
	SqlErr(t) => Err(SqlErr(t))
	BadData(s) => Err(BadData(s))
	TooLarge => Err(TooLarge)
}

## The shape of `Rpc.on`: a function that returns a lambda, the lambda encodes the error of a type variable.
## Domain: `{"Err": <err>}`. Infrastructure: `{"Infra": <tag>}`. The heads are text here (Json), bytes in Cbor.
on = |f| |a| match f(a) {
	Ok(r) => "{\"Ok\":${Json.to_str(r)}}"
	Err(fault) => match domain_or_infra(fault) {
		Ok(e) => "{\"Err\":${Json.to_str(e)}}"
		Err(i) => "{\"Infra\":${Json.to_str(i)}}"
	}
}

## The caller: one closed set for the infrastructure. A pure split, as the caller side of `call!` would do.
Outcome(ret, err) : Try(ret, [RpcErr(Thrown), BadData(Str), Remote(err), Infra(Infra)])

split : Try(ret, Fault(err)) -> Outcome(ret, err)
split = |r| match r {
	Ok(v) => Ok(v)
	Err(fault) => match domain_or_infra(fault) {
		Ok(e) => Err(Remote(e))
		Err(i) => Err(Infra(i))
	}
}

show : Outcome(U64, RoomErr) -> Str
show = |r| match r {
	Ok(v) => "ok ${v.to_str()}"
	Err(Remote(NotOpen)) => "404 not open"
	Err(Remote(AlreadyOpen)) | Err(Remote(StillOpen)) => "409 state"
	Err(Infra(StorageErr(t))) => "503 storage: ${t.message}"
	Err(Infra(i)) => "500 infra: ${Str.inspect(i)}"
	Err(RpcErr(_)) | Err(BadData(_)) => "502 rpc"
}

main! = |_args| {
	run = on(handler)
	for n in [0, 1, 2, 3, 4, 5] {
		echo!("${run(n)}  ${show(split(handler(n)))}\n")
	}
	Ok({})
}
