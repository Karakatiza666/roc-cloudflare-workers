app [event!] {
	pf: platform "../../platform/main.roc",
}

## Q1 control: the CURRENT closed result [RpcErr, BadData], and form B (Remote(err) wrapper).
## Which callers can use `?`?
import pf.Worker

Rpc3(arg, ret, err) :: { name : Str }.{
	method : Str -> Rpc3(arg, ret, err)
	method = |name| Rpc3.{ name }
}

Closeout : { n : U64 }
close_out : Rpc3({}, Closeout, [StillOpen, NotOpen])
close_out = Rpc3.method("close_out")

# Control: today's closed result.
callc : Rpc3(arg, ret, err), arg -> Try(ret, [RpcErr(Str), BadData(Str)])
callc = |_m, _a| Err(RpcErr("x"))

c3 : {} -> Try(U64, [Other, ..])
c3 = |_| {
	c = callc(close_out, {})?
	Ok(c.n)
}

c4 : {} -> Try(U64, [Other, RpcErr(Str), BadData(Str)])
c4 = |_| {
	c = callc(close_out, {})?
	Ok(c.n)
}

# Form B: the declared error rides in one tag.
callb : Rpc3(arg, ret, err), arg -> Try(ret, [RpcErr(Str), BadData(Str), Remote(err)])
callb = |_m, _a| Err(RpcErr("x"))

b1 : {} -> Str
b1 = |_| match callb(close_out, {}) {
	Ok(_) => "ok"
	Err(Remote(StillOpen)) => "still"
	Err(Remote(NotOpen)) => "not"
	Err(RpcErr(_)) => "rpc"
	Err(BadData(_)) => "bad"
}

b3 : {} -> Try(U64, [Other, ..])
b3 = |_| {
	c = callb(close_out, {})?
	Ok(c.n)
}

b4 : {} -> Try(U64, [Other, RpcErr(Str), BadData(Str), Remote([StillOpen, NotOpen])])
b4 = |_| {
	c = callb(close_out, {})?
	Ok(c.n)
}

b5 = |_| {
	c = callb(close_out, {})?
	Ok(c.n)
}

event! : Worker.Event => Worker.Outcome
event! = |_e| crash "x"
