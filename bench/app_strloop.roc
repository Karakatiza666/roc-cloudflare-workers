app [event!] { pf: platform "platform/main.roc" }

import pf.Worker
import pf.Response

## Bug B5: a string that grows in a loop. Request: "<steps>". Body: ",0,1,...,<steps - 1>".
handle! : Str => Str
handle! = |req| {
	steps = U64.from_str(req) ?? 0
	var $s = ""
	var $i = 0.U64
	while $i < steps {
		$s = "${$s},${$i.to_str()}"
		$i = $i + 1
	}
	$s
}

## PLAN.md 8b: the request text is the body of a `Fetch` event (`bench/check.js` `benchEvent`), and the answer is the
## body of `Respond`. A record with no headers, so the answer allocates no more than the text.
event! : Worker.Event => Worker.Outcome
event! = |e| match e {
	Fetch(req) => {
		text = match req.body {
			Bytes(b) => Str.from_utf8(b) ?? ""
			Text(s) => s
			_ => ""
		}
		Respond(Response.{ status: 200, body: Text(handle!(text)) })
	}
	_ => Unhandled
}
