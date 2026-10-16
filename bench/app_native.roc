app [event!] { pf: platform "platform/main.roc" }

import pf.Worker
import pf.Response
import pf.Io
import pf.Native

## The PLAN.md 8e tests of `Native` (`bench/native-test.mjs`). Request: "<case> <args>". Body: the result as text.
## The data of research/native/data/ comes from the op `data` of the test (a file name gives its bytes).

data! : Str => List(U8)
data! = |name| match Io.await!([Call(Root("ops"), "data", [Lit(Text(name))])]) {
	Ok(Bytes(b)) => b
	_ => crash "no data ${name}"
}

digits : List(Str)
digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]

hex : List(U8) -> Str
hex = |bytes| bytes.fold(
	"",
	|acc, b| {
		hi = digits.get(b.to_u64() // 16) ?? "?"
		lo = digits.get(b.to_u64() % 16) ?? "?"
		acc.concat(hi).concat(lo)
	},
)

num : Str -> U64
num = |s| U64.from_str(s) ?? 0

## SHA-256 of `bytes` in chunks, with a `Native.Sha256` handle.
sha! : List(U8), U64 => Str
sha! = |bytes, chunk| {
	h = Native.Sha256.new!({}) ?? crash "sha new"
	for c in bytes.chunks_of(chunk) {
		Native.Sha256.update!(h, c) ?? crash "sha update"
	}
	hex(Native.Sha256.final!(h) ?? crash "sha final")
}

b3! : List(U8), U64 => Str
b3! = |bytes, chunk| {
	h = Native.Blake3.new!({}) ?? crash "b3 new"
	for c in bytes.chunks_of(chunk) {
		Native.Blake3.update!(h, c) ?? crash "b3 update"
	}
	hex(Native.Blake3.final!(h) ?? crash "b3 final")
}

## The handles that a task leaves open: `n` BLAKE3 states and one zstd stream.
open_n! : U64 => {}
open_n! = |n| {
	for _i in 0.U64..<n {
		_h = Native.Blake3.new!({}) ?? crash "open_n"
	}
	_s = Native.ZstdStream.open!({}) ?? crash "open_n stream"
	{}
}

## The recursion of `bench/app_deep.roc` (`down`, with a wide record at each level), with `Native.zstd_decode!` at depth 0.
W : { a : U64, b : U64, c : U64, d : U64, e : U64, f : U64, g : U64, h : U64, i : U64, j : U64, k : U64, l : U64, m : U64, n : U64, o : U64, p : U64 }

m : U64 -> U64
m = |x| x % 1000003

## At depth 0 the base value `x` is the length of the output plus the first 4 bytes of its SHA-256 (little-endian),
## so a wrong or damaged decode changes the result. `name` "-" decodes nothing (x is 0).
down! : U64, U64, Str => W
down! = |n, salt, name| {
	if n == 0 {
		x = if name == "-" 0 else {
			out = Native.zstd_decode!(data!(name), 1_000_000_000) ?? crash "deep decode"
			h = Native.Sha256.new!({}) ?? crash "deep sha"
			Native.Sha256.update!(h, out) ?? crash "deep update"
			d = Native.Sha256.final!(h) ?? crash "deep final"
			first4 = U32.from_le_bytes(d, 0) ?? 0
			out.len() + first4.to_u64()
		}
		{ a: salt + x, b: 1, c: 2, d: 1, e: 3, f: 4, g: 5, h: 6, i: 7, j: 8, k: 9, l: 10, m: 11, n: 12, o: 13, p: 14 }
	} else {
		r = down!(n - 1, m(salt + n * 3), name)
		{ a: m(r.b + n), b: m(r.c * 5 + n), c: m(r.a + r.d), d: r.d + 1, e: m(r.f + r.e), f: m(r.g + n), g: m(r.h * 3), h: m(r.i + 1), i: m(r.j + r.a), j: m(r.k + 2), k: m(r.l + n), l: m(r.m + 3), m: m(r.n + r.b), n: m(r.o + 4), o: m(r.p + n), p: m(r.a + r.c) }
	}
}

handle! : Str => Str
handle! = |req| match req.split_on(" ") {
	["decode", name, limit] => match Native.zstd_decode!(data!(name), num(limit)) {
		Ok(out) => "ok ${out.len().to_str()} ${sha!(out, 65536)}"
		Err(e) => "err ${Str.inspect(e)}"
	}
	["hash", name, chunk] => {
		bytes = data!(name)
		"b3=${b3!(bytes, num(chunk))} sha=${sha!(bytes, num(chunk))}"
	}
	["stream", name, chunk, push_limit] => {
		bytes = data!(name)
		opened = if push_limit == "0" Native.ZstdStream.open!({}) else Native.ZstdStream.open_with!({ push_limit_bytes: num(push_limit) })
		match opened {
			Err(e) => "open err ${Str.inspect(e)}"
			Ok(s) => {
				var $out = []
				var $failed = ""
				for c in bytes.chunks_of(num(chunk)) {
					if $failed == "" {
						match Native.ZstdStream.push!(s, c) {
							Ok(o) => {
								$out = $out.concat(o)
							}
							Err(e) => {
								$failed = Str.inspect(e)
							}
						}
					}
				}
				closed = Native.ZstdStream.close!(s)
				if $failed != "" {
					"err ${$failed} close ${Str.inspect(closed)}"
				} else {
					match closed {
						Ok(_) => "ok ${$out.len().to_str()} ${sha!($out, 65536)}"
						Err(e) => "close err ${Str.inspect(e)}"
					}
				}
			}
		}
	}
	# A handle used after its `final!` is `BadHandle`, and a closed stream too.
	["twice"] => {
		h = Native.Blake3.new!({}) ?? crash "twice"
		_d = Native.Blake3.final!(h) ?? crash "twice final"
		a = Native.Blake3.final!(h)
		b = Native.Blake3.update!(h, [1])
		"final=${Str.inspect(a)} update=${Str.inspect(b)}"
	}
	# More handles than the task may hold.
	["many"] => {
		var $n = 0.U64
		var $err = ""
		for _i in 0.U64..<20 {
			if $err == "" {
				match Native.Sha256.new!({}) {
					Ok(_) => {
						$n = $n + 1
					}
					Err(e) => {
						$err = Str.inspect(e)
					}
				}
			}
		}
		"opened ${$n.to_str()} then ${$err}"
	}
	["limits"] => {
		a = Native.ZstdStream.open_with!({ window_limit_bytes: 16_777_216 })
		"window16M=${Str.inspect(a)}"
	}
	# Handles that the task never closes: it returns (the end of the task frees them).
	["hold", n] => {
		open_n!(num(n))
		"held ${n}"
	}
	# The same, then a trap.
	["crash", n] => {
		open_n!(num(n))
		crash "trap with handles open"
	}
	# Open a handle, wait on the op `gate` (the test controls it), then use the handle.
	["wait", n] => {
		h = Native.Blake3.new!({}) ?? crash "wait new"
		open_n!(num(n))
		_g = Io.await!([Call(Root("ops"), "gate", [])])
		r = Native.Blake3.update!(h, [1, 2, 3])
		"after the wait: update=${Str.inspect(r)}"
	}
	# The allocations of two ops after the wait (the test fails one of them: a clean OOM trap, status 4 of the host).
	["oom"] => {
		_g = Io.await!([Call(Root("ops"), "gate", [])])
		h = Native.Blake3.new!({}) ?? crash "oom new"
		d = Native.Blake3.final!(h) ?? crash "oom final"
		"ok ${hex(d)}"
	}
	# Deep recursion, then `zstd_decode!` at the bottom. "<depth> <name>" (name "-": no decode).
	["deep", depth, name] => {
		_w = Io.await!([Call(Root("ops"), "gate", [])])
		r = down!(num(depth), 17, name)
		"a=${r.a.to_str()} d=${r.d.to_str()} p=${r.p.to_str()}"
	}
	_ => "bad request ${req}"
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
