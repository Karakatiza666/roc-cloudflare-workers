app [event!] { pf: platform "../../platform/main.roc" }

## X6 control: the form of the docs, with a new tag.
import pf.Kv

Meta : { tag : Str }

read! : Kv.Key => Try(Meta, [Other, Missing, Infra([BadData(Str)])])
read! = |key| (key.metadata ? |_| Missing).parse()

event! = |_ev| crash "probe"
