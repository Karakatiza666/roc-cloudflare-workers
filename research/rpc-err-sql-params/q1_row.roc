app [event!] {
	pf: platform "../../platform/main.roc",
}

## Q1 probe. Form A: Rpc(arg, ret, err), call! result [RpcErr(Str), BadData(Str), ..errs].
import pf.Worker
import pf.Cbor

Rpc3(arg, ret, err) :: { name : Str }.{
	method : Str -> Rpc3(arg, ret, err)
	method = |name| Rpc3.{ name }

	## Handler side: the reply is one CBOR item of [Ok(ret), Err(err)].
	reply : Rpc3(arg, ret, err), Try(ret, err) -> List(U8) where [ret.Cbor.Encodable([]), err.Cbor.Encodable([])]
	reply = |_m, r| match r {
		Ok(v) => Cbor.encode(Ok(v))
		Err(e) => Cbor.encode(Err(e))
	}
}

## Caller side over raw reply bytes (the transport is not the question).
## The reply parses as a structural [Ok(ret), Err(err)] (the builtin Try has no codec).
call : Rpc3(arg, ret, err), List(U8) -> Try(ret, [RpcErr(Str), BadData(Str), ..err]) where [ret.Cbor.Parseable([InvalidCbor(U64), ..e1]), err.Cbor.Parseable([InvalidCbor(U64), ..e2])]
call = |_m, bytes| {
	r : Try([Ok(ret), Err(err)], _)
	r = Cbor.parse(bytes)
	match r {
		Ok(Ok(v)) => Ok(v)
		Ok(Err(e)) => Err(e)
		Err(e) => Err(BadData(Str.inspect(e)))
	}
}

Closeout : { n : U64 }
close_out : Rpc3({}, Closeout, [StillOpen, NotOpen])
close_out = Rpc3.method("close_out")

event! : Worker.Event => Worker.Outcome
event! = |_e| crash "x"
