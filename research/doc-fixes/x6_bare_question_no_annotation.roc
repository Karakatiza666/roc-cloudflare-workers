app [event!] { pf: platform "../../platform/main.roc" }

## X6 probe 3: a bare `?` on `key.metadata` in a function with no annotation on it.
import pf.Kv

Meta : { tag : Str }

read! = |key| {
	md = key.metadata?
	m : Meta
	m = md.parse()?
	Ok(m)
}

event! = |_ev| crash "probe"
