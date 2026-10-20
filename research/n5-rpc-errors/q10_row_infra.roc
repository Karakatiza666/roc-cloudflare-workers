## Q10, option G: a combinator that adds an infrastructure tag with a row, as `Io.timeout` does (`[TimedOut, ..e]`).
## Under G: `[Infra([TimedOut]), ..e]`, written with `?` on the result of a call (as `timeout_read` in
## platform/Io.roc). The operation can already give `Infra(...)`: the two payloads merge at the use site.
## The forms with a row inside the payload (`[Infra([TimedOut, ..i]), ..e]`) do not compile: q10_fail.roc.
Thrown : { name : Str, message : Str }

Infra : [KvErr(Thrown), SqlErr(Thrown), TimedOut]

kv : U64 -> Try(U64, [NotFound, Infra([KvErr(Thrown)])])
kv = |n| if (n == 0) Err(NotFound) else if (n == 1) Err(Infra(KvErr({ name: "E", message: "x" }))) else Ok(n)

timeout : (() -> Try(a, e)), Bool -> Try(a, [Infra([TimedOut]), ..e])
timeout = |run, late| {
	if late {
		return Err(Infra(TimedOut))
	}
	v = run()?
	Ok(v)
}

## Exhaustive with no `_`: one `Infra` tag with both payload tags.
plain : U64, Bool -> Str
plain = |n, late| match timeout(|| kv(n), late) {
	Ok(_) => "ok"
	Err(NotFound) => "404"
	Err(Infra(KvErr(_))) => "503 kv"
	Err(Infra(TimedOut)) => "504"
}

## Into the closed error of an Rpc handler.
handler : U64, Bool -> Try(U64, [NotOpen, Infra(Infra)])
handler = |n, late| {
	v = timeout(|| kv(n), late) ? |e| match e {
		NotFound => NotOpen
		Infra(i) => Infra(i)
	}
	Ok(v)
}

main! = |_args| {
	for (n, late) in [(0, Bool.False), (1, Bool.False), (2, Bool.True), (3, Bool.False)] {
		echo!("${plain(n, late)} ${Str.inspect(handler(n, late))}\n")
	}
	Ok({})
}
