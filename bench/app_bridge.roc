app [event!] {
	pf: platform "platform/main.roc",
}

import pf.Worker
import pf.Response
import pf.Js
import pf.Io
# The platform module `Cbor`, a wrapper of the package `roc-cbor` (API.md 5.2). The app has no `cbor` entry.
import pf.Cbor

## The PLAN.md 8a tests of the bridge (`bench/bridge-test.mjs`). Request: "<case> <args>". Body: the result as text.

## A Js value as short text.
show : Js -> Str
show = |v| match v {
	Undefined => "undefined"
	Null => "null"
	Bool(b) => if (b) "true" else "false"
	Num(f) => "num:${f.to_str()}"
	Int(i) => i.to_str()
	Text(s) => "\"${s}\""
	Bytes(b) => "bytes:${b.len().to_str()}"
	Arr(items) => "[${Str.join_with(items.map(show), ",")}]"
	Obj(fields) => "{${Str.join_with(fields.map(|(k, x)| "${k}:${show(x)}"), ",")}}"
	Ref(_) => "ref"
	Error(name, message) => "error:${name}:${message}"
	Packed(b) => "packed:${b.len().to_str()}"
}

shown : Try(Js, Io.Thrown) -> Str
shown = |r| match r {
	Ok(v) => "ok ${show(v)}"
	Err(t) => "err ${t.name}: ${t.message}"
}

yes : Bool -> Str
yes = |b| if (b) "true" else "false"

num : Str -> U64
num = |s| U64.from_str(s) ?? 0

## `ops.sleep(ms, signal)`: one wait of `ms`. The signal of its branch (OP8) goes with it.
sleep : U64 -> Io(Js, Io.Thrown)
sleep = |ms| Io.new([Keep(Root("signal")), Call(Root("ops"), "sleep", [Lit(Int(ms.to_i64_wrap())), Slot(0)])], |r| r)

Row : { id : U64, name : Str, version : Str }

rows_of : List(U8) -> Str
rows_of = |bytes| {
	parsed : Try(List(Row), _)
	parsed = Cbor.parse(bytes)
	match parsed {
		Ok(list) => {
			ids = list.fold(0, |acc, row| acc + row.id)
			last = match list.last() {
				Ok(row) => "${row.name} ${row.version}"
				Err(_) => "-"
			}
			"rows=${list.len().to_str()} ids=${ids.to_str()} last=${last}"
		}
		Err(e) => "parse error ${Str.inspect(e)}"
	}
}

field : List((Str, Js)), Str -> Js
field = |fields, k| match fields.find_first(|(n, _)| n == k) {
	Ok((_, v)) => v
	Err(_) => Undefined
}

deep : U64 -> Js
deep = |n| if (n == 0) Int(7) else Arr([deep(n - 1)])

## HD3: one of each tag, empty and long strings, strings of 11 and 12 bytes (the wasm32 small-string limit),
## 2^53 + 1 and the edges of I64, deep nesting, a ref and an error.
fixtures : Js.Ref -> List(Js)
fixtures = |r| [
	Undefined,
	Null,
	Bool(Bool.True),
	Bool(Bool.False),
	Num(1.5),
	Num(-0.25),
	Num(1e300),
	Int(0),
	Int(-1),
	Int(23),
	Int(24),
	Int(9007199254740993),
	Int(-9007199254740993),
	Int(9223372036854775807),
	Int(-9223372036854775808),
	Text(""),
	Text("eleven byte"),
	Text("twelve bytes"),
	Text("a much longer text that is far past the small string limit"),
	Text("é水😀"),
	Bytes([]),
	Bytes([0, 255, 128]),
	Arr([]),
	Arr([Int(1), Text("x")]),
	Obj([]),
	Obj([("a", Int(1)), ("b_key", Arr([Null, Text("twelve bytes")]))]),
	Ref(r),
	Error("TypeError", "bad thing"),
	deep(50),
]

handle! : Str => Str
handle! = |req| match req.split_on(" ") {
	# A program of 4 ops with one wait: the value of the last op.
	["four"] => shown(Js.await!([Get(Root("ops"), "db"), Call(Slot(0), "prepare", [Lit(Text("select ?"))]), Call(Slot(1), "bind", [Lit(Int(7))]), Call(Slot(2), "raw", [])]))
	# RS1: two refs of one JS object are equal, of another object not.
	["refs"] => {
		a = Js.call!([Call(Root("ops"), "thing", [])])
		b = Js.call!([Call(Root("ops"), "thing", [])])
		c = Js.call!([Call(Root("ops"), "other", [])])
		match (a, b, c) {
			(Ok(Ref(x)), Ok(Ref(y)), Ok(Ref(z))) => "same=${yes(x == y)} other=${yes(x == z)}"
			_ => "bad ${shown(a)}"
		}
	}
	# OP1: a promise in call! (status 2).
	["promise"] => shown(Js.call!([Call(Root("ops"), "sleep", [Lit(Int(1)), Lit(Undefined)])]))
	# OP6: two waits at the same time.
	["both", ms] => match Io.both!(sleep(num(ms)), sleep(num(ms))) {
		Ok((x, y)) => "ok ${show(x)} ${show(y)}"
		Err(t) => "err ${t.name}: ${t.message}"
	}
	# OP6: Par of two sync operations runs with await!.
	["bothsync"] => {
		x = Io.sync([Call(Root("ops"), "name", [Lit(Text("a"))])], |r| r)
		y = Io.sync([Call(Root("ops"), "name", [Lit(Text("b"))])], |r| r)
		match Io.both!(x, y) {
			Ok((a, b)) => "ok ${show(a)} ${show(b)}"
			Err(t) => "err ${t.name}: ${t.message}"
		}
	}
	# OP8: the first to settle wins.
	["race", a, b] => {
		r = Io.race!([sleep(num(a)), sleep(num(b))])
		"index=${r.index.to_str()} ${shown(r.result)}"
	}
	["race0"] => {
		none : List(Io(Js, Io.Thrown))
		none = []
		r = Io.race!(none)
		"index=${r.index.to_str()}"
	}
	# OP7: Get and Fields on null and undefined give Undefined; Call on null throws.
	["null"] => {
		g = Js.call!([Array([Lit(Null)]), Get(Slot(0), "0"), Get(Slot(1), "x")])
		gu = Js.call!([Get(Root("ops"), "missing"), Get(Slot(0), "x")])
		f = Js.call!([Array([Lit(Null)]), Get(Slot(0), "0"), Fields(Slot(1), ["a", "b"])])
		fu = Js.call!([Get(Root("ops"), "missing"), Fields(Slot(0), ["a"])])
		c = Js.call!([Array([Lit(Null)]), Get(Slot(0), "0"), Call(Slot(1), "f", [])])
		"get=${shown(g)} getu=${shown(gu)} fields=${shown(f)} fieldsu=${shown(fu)} call=${shown(c)}"
	}
	# RS2: a CryptoKey pinned by one task, used by a later task.
	["pin", name] => shown(
		Js.await!([
			Get(Root("global"), "crypto"),
			Get(Slot(0), "subtle"),
			Call(Slot(1), "generateKey", [Lit(Obj([("name", Text("HMAC")), ("hash", Text("SHA-256"))])), Lit(Bool(Bool.False)), Lit(Arr([Text("sign"), Text("verify")]))]),
			Call(Root("pf"), "pin", [Lit(Text(name)), Slot(2)]),
		]),
	)
	["use", name] => shown(
		Js.await!([
			Call(Root("pf"), "pinned", [Lit(Text(name))]),
			Get(Root("global"), "crypto"),
			Get(Slot(1), "subtle"),
			Call(Slot(2), "sign", [Lit(Text("HMAC")), Slot(0), Lit(Bytes([1, 2, 3]))]),
			Call(Slot(2), "verify", [Lit(Text("HMAC")), Slot(0), Slot(3), Lit(Bytes([1, 2, 3]))]),
			Fields(Slot(0), ["type", "extractable"]),
			Array([Slot(3), Slot(4), Slot(5)]),
		]),
	)
	# API.md 5.2: rows as one Packed value, read by Cbor.parse.
	["pack", n] => match Js.await!([Call(Root("ops"), "rows", [Lit(Int(num(n).to_i64_wrap()))]), Call(Root("pf"), "pack", [Slot(0)])]) {
		Ok(Packed(bytes)) => "packed ${rows_of(bytes)}"
		other => "bad ${shown(other)}"
	}
	# 6.4: the field `results` of each item as Packed.
	["packeach"] => match Js.await!([Call(Root("ops"), "batch", []), Call(Root("pf"), "packEach", [Slot(0), Lit(Text("results"))])]) {
		Ok(Arr(items)) => {
			each = items.map(
				|item| match item {
					Obj(fs) => match field(fs, "results") {
						Packed(bytes) => "${rows_of(bytes)} meta=${show(field(fs, "meta"))}"
						other => "results=${show(other)}"
					}
					other => "item=${show(other)}"
				},
			)
			"items=${items.len().to_str()} ${Str.join_with(each, "; ")}"
		}
		other => "bad ${shown(other)}"
	}
	# 6.4: the item of an id, or undefined.
	["find", id] => shown(Js.call!([Call(Root("ops"), "messages", []), Call(Root("pf"), "findById", [Slot(0), Lit(Text(id))])]))
	# HD3: Roc values to JS and back.
	["hd3"] => match Js.call!([Call(Root("ops"), "thing", [])]) {
		Ok(Ref(r)) => {
			want = fixtures(r)
			back = Js.call!([Array(want.map(|v| Lit(v)))])
			packed = Js.call!([Array([Lit(Packed(Cbor.encode([1.U8, 2])))])])
			match back {
				Ok(Arr(got)) => {
					bad = want.map2(got, |w, g| if (w == g) "" else "${show(w)} != ${show(g)}").keep_if(|s| s != "")
					"hd3 ${yes(got.len() == want.len() and bad.is_empty())} ${got.len().to_str()} ${Str.join_with(bad, "; ")} packed=${shown(packed)}"
				}
				_ => "bad ${shown(back)}"
			}
		}
		other => "bad ${shown(other)}"
	}
	# HD6: n decodes of the fixtures, each dropped.
	["hd6", n] => match Js.call!([Call(Root("ops"), "thing", [])]) {
		Ok(Ref(r)) => {
			fix = fixtures(r).map(|v| Lit(v))
			var $ok = 0.U64
			for _ in (0.U64).until(num(n)) {
				match Js.call!([Array(fix)]) {
					Ok(Arr(got)) => {
						$ok = $ok + (if (got.len() == fix.len()) 1 else 0)
					}
					_ => {}
				}
			}
			"hd6 ${$ok.to_str()}"
		}
		other => "bad ${shown(other)}"
	}
	# 10c: a task with refs that ends, traps or is cancelled while it waits.
	["objs", mode, n] => {
		got = Js.call!([Call(Root("ops"), "objs", [Lit(Int(num(n).to_i64_wrap()))])])
		_ = Js.await!([Keep(Root("signal")), Call(Root("ops"), "tick", [Slot(0)])])
		match mode {
			"trap" => crash "trap after the refs"
			"hang" => shown(Js.await!([Call(Root("ops"), "hang", [])]))
			_ => match got {
				Ok(Arr(items)) => "objs ${items.len().to_str()}"
				_ => "bad ${shown(got)}"
			}
		}
	}
	# One op of `ops` with no argument, with one wait.
	["op", name] => shown(Js.await!([Call(Root("ops"), name, [])]))
	# 6.5: a started program runs after the task (it keeps the context of the task).
	["start", ms] => {
		_ = Io.start!(sleep(num(ms)))
		"started"
	}
	_ => "unknown request ${req}"
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
