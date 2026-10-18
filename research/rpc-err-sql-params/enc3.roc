app [event!] {
	pf: platform "../../platform/main.roc",
}

## Q2 and Q1: NULL in tuples, a platform null value, round trips of tags.
import pf.Worker
import pf.Cbor

hex : List(U8) -> Str
hex = |bs| Str.join_with(bs.map(|b| b.to_str()), ",")

show : Str, List(U8) -> {}
show = |label, bs| dbg "${label} => [${hex(bs)}]"

## Candidate platform values (Sql.null, Sql.blob).
null : {} -> Try(a, [Null])
null = |{}| Err(Null)

## Option 2: a nominal Null type with its own encoder (CBOR null).
Nul := [Nul].{
	encoder_for : encoding -> (Nul, state -> Try(state, err))
		where [encoding.encode_null : state -> Try(state, err)]
	encoder_for = |_| {
		Enc : encoding
		|_, state| Enc.encode_null(state)
	}
}
nul : Nul
nul = Nul.Nul

blob : List(U8) -> Cbor.Bytes
blob = |l| Cbor.bytes(l)

some : a -> Try(a, [Null])
some = |x| Ok(x)

Reply(ret, err) := [Ok(ret), Err(err)].{
	parser_for : _
	encoder_for : _
	is_eq : _
}
Closeout : { n : U64 }
Dumb : [StillOpen, NotOpen, Busy(Str), Pair(U64, Str)]

expect {
	# A: annotated Try item in a tuple
	a1 : Try(I64, [Null])
	a1 = Err(Null)
	show("A tuple (id, Try-Null, name)", Cbor.encode((7.I64, a1, "x")))
	# B: Sql.null with the type left open
	show("B2 tuple (7, nul, x)", Cbor.encode((7.I64, nul, "x")))
	show("B3 list [nul]", Cbor.encode([nul]))
	# C: blob and some
	show("C tuple (blob, some(5))", Cbor.encode((blob([1, 2]), some(5.I64))))
	# D: list of one null
	d1 : List(Try(I64, [Null]))
	d1 = [null({})]
	show("D list [null]", Cbor.encode(d1))
	show("G tuple (7, Err(Null), x) unannotated", Cbor.encode((7.I64, Err(Null), "x")))
	show("G2 tuple (7, Ok(5), x) unannotated", Cbor.encode((7.I64, Ok(5.I64), "x")))
	# E: round trips of the reply
	w1 : Reply(Closeout, Dumb)
	w1 = Reply.Err(Pair(7, "y"))
	r : Try(Reply(Closeout, Dumb), _)
	r = Cbor.parse(Cbor.encode(w1))
	show("E parse Err(Pair) ok?", [if r == Ok(w1) 1 else 0])
	w2 : Reply(Closeout, Dumb)
	w2 = Reply.Err(StillOpen)
	r2 : Try(Reply(Closeout, Dumb), _)
	r2 = Cbor.parse(Cbor.encode(w2))
	show("E parse Err(StillOpen) ok?", [if r2 == Ok(w2) 1 else 0])
	# F: a tag that the caller type does not list
	w3 : Reply(Closeout, Dumb)
	w3 = Reply.Err(Busy("x"))
	r3 : Try(Reply(Closeout, [StillOpen, NotOpen]), _)
	r3 = Cbor.parse(Cbor.encode(w3))
	show("F unknown tag parse is Err?", [if r3.is_err() 1 else 0])
	Bool.True
}
event! : Worker.Event => Worker.Outcome
event! = |_e| crash "x"
