app [handle!] { pf: platform "platform/main.roc" }

import pf.Wait

W : { a : U64, b : U64, c : U64, d : U64, e : U64, f : U64, g : U64, h : U64 }

## Effectful recursion: at depth 0, a wait with `kind` (99: out-of-bounds write, 98: unreachable).
down! : U64, U32 => W
down! = |n, kind| {
	if n == 0 {
		w = Wait.wait!(kind, 0, "x", "", [])
		{ a: w.status.to_u64(), b: 1, c: 2, d: 3, e: 4, f: 5, g: 6, h: 7 }
	} else {
		r = down!(n - 1, kind)
		{ a: r.b + n, b: r.c + 1, c: r.a + r.d, d: r.d + 1, e: r.f, f: r.g + n, g: r.h, h: r.a }
	}
}

## Request: "<kind> <depth> [<steps>]"
handle! : Str => Str
handle! = |req| {
	_w = Wait.wait!(2, 0, "x", "", [])
	parts = req.split_on(" ")
	kind = U32.from_str(parts.get(0) ?? "2") ?? 2
	depth = U64.from_str(parts.get(1) ?? "0") ?? 0
	steps = U64.from_str(parts.get(2) ?? "") ?? (depth + 40)
	# Heap data that lives across the waits, and goes into the body.
	var $held = ""
	var $i = 0.U64
	while $i < steps {
		$held = "${$held},${$i.to_str()}"
		$i = $i + 1
	}
	held = $held
	r = down!(depth, kind)
	_w2 = Wait.wait!(2, 0, "y", "", [])
	"a=${r.a.to_str()} d=${r.d.to_str()} held=${held}"
}
