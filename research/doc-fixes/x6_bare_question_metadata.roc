app [event!] { pf: platform "../../platform/main.roc" }

## X6 probe 1: a bare `?` on `key.metadata`; the error union of the annotation has no `Missing`.
import pf.Kv
import pf.Io

Meta : { tag : Str }

read! : Kv.Key => Try(Meta, [Other, Infra([BadData(Str)])])
read! = |key| {
	md = key.metadata?
	m = md.parse()?
	Ok(m)
}

event! = |_ev| crash "probe"
