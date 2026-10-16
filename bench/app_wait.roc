app [handle!] { pf: platform "../platform/main.roc" }

import pf.Wait

## One wait, and no heap allocation by the app (`bench/cpu-test.mjs`: the CPU check in `waitBegin` alone). Body: "ok".
handle! : Str => Str
handle! = |_req| {
	_w = Wait.wait!(2, 0, "x", "", [])
	"ok"
}
