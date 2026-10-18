app [event!] {
	pf: platform "../../platform/main.roc",
}
import pf.Worker
import pf.Cbor

t1 : Try(U64, [StillOpen, NotOpen])
t1 = Err(StillOpen)

e1 = Cbor.encode(t1)

s1 : [Ok(U64), Err([StillOpen, NotOpen])]
s1 = Ok(5)
e2 = Cbor.encode(s1)

event! : Worker.Event => Worker.Outcome
event! = |_e| crash "x"
