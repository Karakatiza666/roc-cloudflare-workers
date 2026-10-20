## Q6: a nested call in a handler. Can a value of the closed `Infra` be a `Fault(err)` with no match?
## And a forward helper: the outcome of a call, as the fault of the handler that made it.
Thrown : { name : Str, message : Str }

Infra : [StorageErr(Thrown), TooLarge, RpcErr(Thrown), BadData(Str)]

Fault(err) : [Fail(err), StorageErr(Thrown), TooLarge, RpcErr(Thrown), BadData(Str)]

## (a) The value as it is (`|i| i`) does not compile (q6_widen_fail.roc). A match, written once in the platform.
widen : Infra -> Fault(err)
widen = |i| match i {
	StorageErr(t) => StorageErr(t)
	TooLarge => TooLarge
	RpcErr(t) => RpcErr(t)
	BadData(s) => BadData(s)
}

## (b) The caller result of a nested call, forwarded: same domain, or a map of the domain.
forward : Try(ret, [RpcErr(Thrown), BadData(Str), Remote(err), Infra(Infra)]), (err -> e2) -> Try(ret, Fault(e2))
forward = |r, f| match r {
	Ok(v) => Ok(v)
	Err(RpcErr(t)) => Err(RpcErr(t))
	Err(BadData(s)) => Err(BadData(s))
	Err(Remote(e)) => Err(Fail(f(e)))
	Err(Infra(i)) => Err(widen(i))
}

handler : U64 -> Try(U64, Fault([Upstream([StillOpen])]))
handler = |n| {
	r : Try(U64, [RpcErr(Thrown), BadData(Str), Remote([StillOpen]), Infra(Infra)])
	r = if (n == 0) Err(Remote(StillOpen)) else if (n == 1) Err(Infra(TooLarge)) else Ok(n)
	v = forward(r, |e| Upstream(e))?
	Ok(v)
}

main! = |_args| {
	for n in [0, 1, 2] {
		echo!("${Str.inspect(handler(n))}\n")
	}
	Ok({})
}
