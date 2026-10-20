app [event!] { pf: platform "../../platform/main.roc" }

## Q5: an alias with a row variable, closed with `[]`, has no derived CBOR codec. Closed with a tag, it has one.
import pf.Cbor
import pf.Worker

InfraOr(e) : [StorageErr(Str), TooLarge, ..e]

## Compiles.
with_tag : InfraOr([NotOpen]) -> List(U8)
with_tag = |e| Cbor.encode(e)

## "missing method encoder_for".
with_empty : InfraOr([]) -> List(U8)
with_empty = |e| Cbor.encode(e)

event! : Worker.Event => Worker.Outcome
event! = |_e| crash "x"
