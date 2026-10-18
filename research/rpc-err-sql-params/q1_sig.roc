app [event!] {
	pf: platform "../../platform/main.roc",
}

## Q1 probe, form A signature only (bodies crash): can a caller use the row merge?
import pf.Worker

Rpc3(arg, ret, err) :: { name : Str }.{
	method : Str -> Rpc3(arg, ret, err)
	method = |name| Rpc3.{ name }
}

call : Rpc3(arg, ret, err), arg -> Try(ret, [RpcErr(Str), BadData(Str), ..err])
call = |_m, _a| crash "stub"

Closeout : { n : U64 }
close_out : Rpc3({}, Closeout, [StillOpen, NotOpen])
close_out = Rpc3.method("close_out")

# 1. match on the declared tags
m1 : {} -> Str
m1 = |_| match call(close_out, {}) {
	Ok(_) => "ok"
	Err(StillOpen) => "still"
	Err(NotOpen) => "not"
	Err(RpcErr(_)) => "rpc"
	Err(BadData(_)) => "bad"
}

# 2. ? in a function with an inferred open error
f2 = |_| {
	c = call(close_out, {})?
	Ok(c.n)
}

# 3. ? in a function with a declared open union
f3 : {} -> Try(U64, [Other, ..])
f3 = |_| {
	c = call(close_out, {})?
	Ok(c.n)
}

# 4. ? in a function with a declared closed superset
f4 : {} -> Try(U64, [Other, StillOpen, NotOpen, RpcErr(Str), BadData(Str)])
f4 = |_| {
	c = call(close_out, {})?
	Ok(c.n)
}

# 5. `_` error
f5 : {} -> Try(U64, _)
f5 = |_| {
	c = call(close_out, {})?
	Ok(c.n)
}

event! : Worker.Event => Worker.Outcome
event! = |_e| crash "x"
