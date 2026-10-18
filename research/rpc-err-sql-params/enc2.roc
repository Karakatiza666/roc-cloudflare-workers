app [event!] {
	pf: platform "../../platform/main.roc",
}

## Q2: encodings of roc-cbor 0.1.0 shown by `roc test`.
import pf.Worker
import pf.Cbor

hex : List(U8) -> Str
hex = |bs| Str.join_with(bs.map(|b| b.to_str()), ",")

show : Str, List(U8) -> {}
show = |label, bs| dbg "${label} => [${hex(bs)}]"



OptRec : { id : U64, note ?: Str }

t_opt_try : Try(Str, [Null])
t_opt_try = Err(Null)
t_opt_try2 : Try(Str, [Null])
t_opt_try2 = Ok("a")

expect {
	show("tuple (1,\"a\",2.5.F64)", Cbor.encode((1.I64, "a", 2.5.F64)))
	show("tuple2 (1,\"a\")", Cbor.encode((1.I64, "a")))
	show("List(U8) [1,2,3]", Cbor.encode([1, 2, 3].map(|x| x.to_u8())))
	show("List(U8) [200]", Cbor.encode([200.U8]))
	show("Cbor.bytes [1,2,3]", Cbor.encode(Cbor.bytes([1, 2, 3])))
	show("List [7.I64]", Cbor.encode([7.I64]))
	show("List []", Cbor.encode(List.repeat(1.I64, 0)))
	show("empty tuple {} ", Cbor.encode({}))
	show("tag Null in [Null,Other]", Cbor.encode(x1))
	show("tag Ok(5) in [Ok(I64),Err(Str)]", Cbor.encode(x2))
	show("Err(Null) in [Ok(Str),Err([Null])]", Cbor.encode(x3))
	show("Try(Str,[Null]) Err(Null)", Cbor.encode(t_opt_try))
	show("Try(Str,[Null]) Ok(a)", Cbor.encode(t_opt_try2))
	show("rec {id, note absent}", Cbor.encode(r1))
	show("rec {id, note present}", Cbor.encode(r2))
	show("tuple with Cbor.bytes", Cbor.encode((1.I64, Cbor.bytes([9, 8]))))
	Bool.True
}

x1 : [Null, Other]
x1 = Null
x2 : [Ok(I64), Err(Str)]
x2 = Ok(5)
x3 : [Ok(Str), Err([Null])]
x3 = Err(Null)
r1 : OptRec
r1 = { id: 1 }
r2 : OptRec
r2 = { id: 1, note: "n" }
event! : Worker.Event => Worker.Outcome
event! = |_e| crash "x"
