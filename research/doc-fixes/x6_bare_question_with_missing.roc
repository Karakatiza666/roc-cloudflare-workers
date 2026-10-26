app [event!] { pf: platform "../../platform/main.roc" }

## X6 probe 2: a bare `?` on `key.metadata`; the error union of the annotation has `Missing`.
import pf.Kv

Meta : { tag : Str }

read! : Kv.Key => Try(Meta, [Other, Missing, Infra([BadData(Str)])])
read! = |key| {
	md = key.metadata?
	m = md.parse()?
	Ok(m)
}

event! = |_ev| crash "probe"
