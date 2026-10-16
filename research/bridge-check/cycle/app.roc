app [handle!] { pf: platform "main.roc" }

import pf.Js

handle! : Str => Str
handle! = |req| match Js.await!(Text(req)) {
	Text(s) => s
	_ => ""
}
