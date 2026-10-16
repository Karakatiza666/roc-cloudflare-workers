app [event!] { pf: platform "platform/main.roc" }

import pf.Worker
import pf.Response
import pf.Io

## One wait: the op `db` of the bench runner (`bench/core.js`).
wait_ops = [Call(Root("ops"), "db", [Lit(Text("x"))])]

## `waits` waits. A function of its own, and recursive, so it is not inlined: the frame of `down!` stays small
## (the locals of `Io.await!` are in this frame, once, at the bottom).
wait_n! : U64 => U64
wait_n! = |waits| {
	if waits == 0 {
		0
	} else {
		_w = Io.await!(wait_ops)
		wait_n!(waits - 1)
	}
}

## Recurse `n` levels, wait `waits` times at depth 0, then check each level on the way up.
## The canary of a level is a small string ("<salt>:<n>", up to 11 bytes): its bytes are inside
## the string value, in the frame of the level (the shadow stack), and the level reads it after
## the waits. Returns the number of wrong canaries.
down! : U64, U64, U64 => U64
down! = |n, salt, waits| {
	tag = "${salt.to_str()}:${n.to_str()}"
	below = if n == 0 {
		wait_n!(waits)
	} else {
		down!(n - 1, salt, waits)
	}
	want = salt.to_str().concat(":").concat(n.to_str())
	below + (if tag == want 0 else 1)
}

## Request: "<salt> <depth> <waits>", salt below 100000. Body: "bad=<wrong canaries>".
handle! : Str => Str
handle! = |req| {
	parts = req.split_on(" ")
	salt = U64.from_str(parts.get(0) ?? "1") ?? 1
	depth = U64.from_str(parts.get(1) ?? "10") ?? 10
	waits = U64.from_str(parts.get(2) ?? "1") ?? 1
	"bad=${down!(depth, salt, waits).to_str()}"
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
