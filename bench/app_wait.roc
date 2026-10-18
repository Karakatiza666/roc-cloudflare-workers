app [event!] { pf: platform "platform/main.roc" }

import pf.Worker
import pf.Response
import pf.Js

## One wait, and no heap allocation by the app (`bench/cpu-test.mjs`: the CPU check in `waitBegin` alone). The program
## is empty: an empty list has no heap block. Body: "ok".
handle! : Str => Str
handle! = |_req| {
	_w = Js.await!([])
	"ok"
}

## PLAN.md 8b: the request text is the body of a `Fetch` event (`bench/check.js` `benchEvent`), and the answer is the
## body of `Respond`. A record with no headers, so the answer allocates no more than the text.
event! : Worker.Event => Worker.Outcome
event! = |e| match e {
	Fetch(req) => {
		text = match req.body() {
			Bytes(b) => Str.from_utf8(b) ?? ""
			Text(s) => s
			_ => ""
		}
		Respond(Response.from_status(200).with_body(Text(handle!(text))))
	}
	_ => Unhandled
}
