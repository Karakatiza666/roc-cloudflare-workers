app [event!] {
	pf: platform "../../platform/main.roc",
}

## Q1 probe: a generic reply wire type, and the body of a row-merging call.
import pf.Worker
import pf.Cbor

## The wire reply. A nominal type that derives its codec.
Reply(ret, err) := [Ok(ret), Err(err)].{
	parser_for : _
	encoder_for : _
}

enc : Try(ret, err) -> List(U8) where [ret.Cbor.Encodable([]), err.Cbor.Encodable([])]
enc = |r| match r {
	Ok(v) => Cbor.encode(Reply.Ok(v))
	Err(e) => Cbor.encode(Reply.Err(e))
}

# Body of the closed-result form B: compiles when the wire type is generic.
decode_b : List(U8) -> Try(ret, [BadData(Str), Remote(err)]) where [ret.Cbor.Parseable([InvalidCbor(U64), ..e1]), err.Cbor.Parseable([InvalidCbor(U64), ..e2])]
decode_b = |bytes| {
	r : Try(Reply(ret, err), _)
	r = Cbor.parse(bytes)
	match r {
		Ok(Reply.Ok(v)) => Ok(v)
		Ok(Reply.Err(e)) => Err(Remote(e))
		Err(e) => Err(BadData(Str.inspect(e)))
	}
}

# Body of the open-row form A: the declared err value must become a row. Expected to fail.
decode_a : List(U8) -> Try(ret, [BadData(Str), ..err]) where [ret.Cbor.Parseable([InvalidCbor(U64), ..e1]), err.Cbor.Parseable([InvalidCbor(U64), ..e2])]
decode_a = |bytes| {
	r : Try(Reply(ret, err), _)
	r = Cbor.parse(bytes)
	match r {
		Ok(Reply.Ok(v)) => Ok(v)
		Ok(Reply.Err(e)) => Err(e)
		Err(e) => Err(BadData(Str.inspect(e)))
	}
}

event! : Worker.Event => Worker.Outcome
event! = |_e| crash "x"
