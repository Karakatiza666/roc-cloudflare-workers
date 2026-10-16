app [event!] { pf: platform "platform/main.roc" }

import pf.Worker
import pf.Response
import pf.Io

## One wait: the op `db` of the bench runner (`bench/core.js`).
wait_ops = [Call(Root("ops"), "db", [Lit(Text("x"))])]

## A wide record, so each level uses more shadow stack than engine stack.
W : { a : U64, b : U64, c : U64, d : U64, e : U64, f : U64, g : U64, h : U64, i : U64, j : U64, k : U64, l : U64, m : U64, n : U64, o : U64, p : U64 }

m : U64 -> U64
m = |x| x % 1000003

## Recursion that returns a wide record (on the shadow stack) at each level.
## alloc: also allocate a list at each level, so the allocator checks the stack canary.
## `bench/overflow-test.mjs` computes the same result.
down : U64, U64, Bool -> W
down = |n, salt, alloc| {
	if n == 0 {
		{ a: salt, b: 1, c: 2, d: 1, e: 3, f: 4, g: 5, h: 6, i: 7, j: 8, k: 9, l: 10, m: 11, n: 12, o: 13, p: 14 }
	} else {
		extra = if alloc List.repeat(n, 2).len() else 0
		r = down(n - 1, m(salt + n * 3), alloc)
		{ a: m(r.b + n + extra), b: m(r.c * 5 + n), c: m(r.a + r.d), d: r.d + 1, e: m(r.f + r.e), f: m(r.g + n), g: m(r.h * 3), h: m(r.i + 1), i: m(r.j + r.a), j: m(r.k + 2), k: m(r.l + n), l: m(r.m + 3), m: m(r.n + r.b), n: m(r.o + 4), o: m(r.p + n), p: m(r.a + r.c) }
	}
}

## The recursion of `down` with no allocation. One list, made at the top, goes down the levels and
## is freed at depth 0, so the free runs at the deepest frame (PLAN.md 4-pre, the canary check at free).
down_free : U64, U64, List(U64) -> W
down_free = |n, salt, keep| {
	if n == 0 {
		# `set` takes the list (unique: in place), and the list is freed after its last use here.
		mine = keep.set(0, 5) ?? []
		x = mine.get(0) ?? 0
		{ a: salt + x, b: 1, c: 2, d: 1, e: 3, f: 4, g: 5, h: 6, i: 7, j: 8, k: 9, l: 10, m: 11, n: 12, o: 13, p: 14 }
	} else {
		r = down_free(n - 1, m(salt + n * 3), keep)
		{ a: m(r.b + n), b: m(r.c * 5 + n), c: m(r.a + r.d), d: r.d + 1, e: m(r.f + r.e), f: m(r.g + n), g: m(r.h * 3), h: m(r.i + 1), i: m(r.j + r.a), j: m(r.k + 2), k: m(r.l + n), l: m(r.m + 3), m: m(r.n + r.b), n: m(r.o + 4), o: m(r.p + n), p: m(r.a + r.c) }
	}
}

## Request: "<depth>", "<depth> alloc" or "<depth> free". The first wait makes the call a task, as in the real handler.
handle! : Str => Str
handle! = |req| {
	_w = Io.await!(wait_ops)
	depth = U64.from_str(req.drop_suffix(" alloc").drop_suffix(" free")) ?? 10
	r = if req.ends_with(" free") down_free(depth, 17, List.repeat(0, 100)) else down(depth, 17, req.ends_with(" alloc"))
	"a=${r.a.to_str()} d=${r.d.to_str()} p=${r.p.to_str()}"
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
