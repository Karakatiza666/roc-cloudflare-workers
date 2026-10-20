app [event!] { pf: platform "../../platform/main.roc" }

## Q4: the derived CBOR codec of a structural tag whose payload is a constrained type variable, in generic code.
import pf.Cbor
import pf.Worker

## Control: the type variable alone. Compiles.
enc_plain : err -> List(U8) where [err.Cbor.Writable]
enc_plain = |e| Cbor.encode(e)

## The same value in a structural tag: "missing method encoder_for".
enc_tag : err -> List(U8) where [err.Cbor.Writable]
enc_tag = |e| Cbor.encode(Fail(e))

event! : Worker.Event => Worker.Outcome
event! = |_e| crash "x"
