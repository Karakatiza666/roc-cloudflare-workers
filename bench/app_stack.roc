app [handle!] { pf: platform "../platform/main.roc" }

import pf.Wait

## Recurse `n` levels, wait `waits` times at depth 0, then check each level on the way up.
## The canary of a level is a small string ("<salt>:<n>", up to 11 bytes): its bytes are inside
## the string value, in the frame of the level (the shadow stack), and the level reads it after
## the waits. Returns the number of wrong canaries.
down! : U64, U64, U64 => U64
down! = |n, salt, waits| {
	tag = "${salt.to_str()}:${n.to_str()}"
	below = if n == 0 {
		for _ in (0.U64).until(waits) {
			_w = Wait.wait!(2, 0, "x", "", [])
		}
		0
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
