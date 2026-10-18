app [event!] {
	pf: platform "../../platform/main.roc",
}

## Encodings of roc-cbor 0.1.0, shown by `roc test` (dbg prints, expect checks).
import pf.Worker
import pf.Cbor

Reply(ret, err) := [Ok(ret), Err(err)].{
	parser_for : _
	encoder_for : _
}
Closeout : { n : U64 }
Dumb : [StillOpen, NotOpen, Busy(Str), Pair(U64, Str)]

hex : List(U8) -> Str
hex = |bs| Str.join_with(bs.map(|b| b.to_str()), ",")

show : Str, List(U8) -> {}
show = |label, bs| dbg "${label} => [${hex(bs)}]"

ok_val : Reply(Closeout, Dumb)
ok_val = Reply.Ok({ n: 3 })
err_np : Reply(Closeout, Dumb)
err_np = Reply.Err(StillOpen)
err_p : Reply(Closeout, Dumb)
err_p = Reply.Err(Busy("x"))
err_2 : Reply(Closeout, Dumb)
err_2 = Reply.Err(Pair(7, "y"))

expect {
	show("Reply Ok({n:3})", Cbor.encode(ok_val))
	show("Reply Err(StillOpen)", Cbor.encode(err_np))
	show("Reply Err(Busy(x))", Cbor.encode(err_p))
	show("Reply Err(Pair(7,y))", Cbor.encode(err_2))
	show("tag no payload Null", Cbor.encode(Null) )
	Bool.True
}
event! : Worker.Event => Worker.Outcome
event! = |_e| crash "x"
