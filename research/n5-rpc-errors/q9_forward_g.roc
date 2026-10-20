## Q9, option G: `forward` for a nested call in a handler. The call gives `[Infra([RpcErr, BadData]), Remote(err)]`.
## The callee's `err` has its own `Infra(Infra)`. `forward(f)` is the function for `?`: the errors of this hop stay in
## `Infra`, `f` maps the callee's error (`|e| e` when both have the same type).
Thrown : { name : Str, message : Str }

Infra : [StorageErr(Thrown), RpcErr(Thrown), BadData(Str), TooLarge]

forward : (err -> [Infra(Infra), ..e]) -> ([Infra([RpcErr(Thrown), BadData(Str)]), Remote(err)] -> [Infra(Infra), ..e])
forward = |f| |x| match x {
	Infra(RpcErr(t)) => Infra(RpcErr(t))
	Infra(BadData(s)) => Infra(BadData(s))
	Remote(e) => f(e)
}

RoomErr : [NotOpen, StillOpen, Infra(Infra)]

call : U64 -> Try(U64, [Infra([RpcErr(Thrown), BadData(Str)]), Remote(RoomErr)])
call = |n| if (n == 0) Err(Remote(StillOpen)) else if (n == 1) Err(Remote(Infra(StorageErr({ name: "E", message: "disk" })))) else if (n == 2) Err(Infra(RpcErr({ name: "E", message: "gone" }))) else Ok(n)

## The same error type: `|e| e`.
same : U64 -> Try(U64, RoomErr)
same = |n| {
	v = call(n) ? forward(|e| e)
	Ok(v)
}

## Another domain: the callee's domain tags mapped, its `Infra` kept.
LedgerErr : [Busy, Infra(Infra)]

other : U64 -> Try(U64, LedgerErr)
other = |n| {
	v = call(n) ? forward(
		|e| match e {
			NotOpen | StillOpen => Busy
			Infra(i) => Infra(i)
		},
	)
	Ok(v)
}

main! = |_args| {
	for n in [0, 1, 2, 3] {
		echo!("${Str.inspect(same(n))} ${Str.inspect(other(n))}\n")
	}
	Ok({})
}
