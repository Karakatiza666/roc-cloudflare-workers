app [event!] { pf: platform "platform/main.roc" }

import pf.Worker
import pf.Response
import pf.Js
import pf.Io

## A package row of the registry, to make realistic heap data.
Item : { id : U64, name : Str, version : Str, summary : Str, tags : List(Str), downloads : U64, yanked : Bool }

## One op of the bench runner (`bench/core.js`: `ops.fetch` and `ops.db` call the `io` of a test). The roots `env`,
## `ctx` and `event` of the task go to the op as its last three arguments (PLAN.md 9b). Body: the text it gives,
## or "" when it throws or gives no text.
effect! : Str, List(Js.Arg) => Str
effect! = |name, args| {
	ops = [Keep(Root("env")), Keep(Root("ctx")), Keep(Root("event")), Call(Root("ops"), name, args.concat([Slot(0), Slot(1), Slot(2)]))]
	match Js.await!(ops) {
		Ok(Text(s)) => s
		_ => ""
	}
}

## Kind 1: a fetch through the service binding (body: the echo).
fetch! : Str => Str
fetch! = |url| effect!("fetch", [Lit(Text("GET")), Lit(Text(url))])

## Kind 2: a "db" query.
db! : Str => Str
db! = |q| effect!("db", [Lit(Text(q))])

items : Str, U64 -> List(Item)
items = |id, count| {
	var $out = List.with_capacity(count)
	for i in (0.U64).until(count) {
		n = i.to_str()
		$out = $out.append({
			id: i,
			name: "package-${n}-for-${id}",
			version: "${(i % 7).to_str()}.${(i % 13).to_str()}.${n}",
			summary: "A Roc package number ${n}, with a summary long enough to need a heap string, for request ${id}.",
			tags: ["roc", "tag-${(i % 5).to_str()}", "group-${(i % 11).to_str()}"],
			downloads: i * 1013,
			yanked: i % 17 == 0,
		})
	}
	$out
}

## Recurse `n` levels. Each level keeps a record with a heap string across the
## waits at the bottom, then checks it, so a bad stack restore changes `sum`.
deep! : U64, Str, Bool => { sum : U64, out : Str }
deep! = |n, id, trap| {
	if n == 0 {
		f = fetch!("http://echo/f?id=${id}")
		if trap {
			crash "trap after the first wait"
		}
		d = db!("select ${id}")
		{ sum: 0, out: "fetch=${f} db=${d}" }
	} else {
		mine = { level: n, tag: "level-${n.to_str()}-of-request-${id}" }
		r = deep!(n - 1, id, trap)
		good = if (mine.tag.ends_with(id)) 1 else 1000000
		{ sum: r.sum + mine.level * 1000 + mine.tag.count_utf8_bytes() + good, out: r.out }
	}
}

## Request: "<id> <trap: 0|1> <depth> <items> [dbg|-] [<mb>]". With `dbg`, the request writes 200 `dbg` lines
## after its waits and then crashes (`bench/log-test.mjs`). With `<mb>`, it holds that many MB across its waits
## (`bench/budget-test.mjs`). Body: "id=<id> json=<bytes> sum=<sum> fetch=<echo> db=<echo>", and "alloc=<byte>" after
## the json part when it holds memory.
handle! : Str => Str
handle! = |req| {
	parts = req.split_on(" ")
	id = parts.first() ?? "none"
	trap = parts.get(1) == Ok("1")
	depth = match parts.get(2) {
		Ok(s) => U64.from_str(s) ?? 50
		Err(_) => 50
	}
	count = match parts.get(3) {
		Ok(s) => U64.from_str(s) ?? 200
		Err(_) => 200
	}
	mb = match parts.get(5) {
		Ok(s) => U64.from_str(s) ?? 0
		Err(_) => 0
	}
	held = List.repeat(7.U8, mb * 1048576)
	json = Json.to_str(items(id, count))
	r = deep!(depth, id, trap)
	if parts.get(4) == Ok("dbg") {
		for i in (0.U64).until(200) {
			dbg "request ${id} line ${i.to_str()}"
		}
		crash "crash after dbg of request ${id}"
	}
	# The last byte keeps the held memory live until here.
	alloc = match held.last() {
		Ok(b) => " alloc=${b.to_str()}"
		Err(_) => ""
	}
	"id=${id} json=${json.count_utf8_bytes().to_str()}${alloc} sum=${r.sum.to_str()} ${r.out}"
}

## PLAN.md 8b: the request text is the body of a `Fetch` event (`bench/check.js` `benchEvent`), and the answer is the
## body of `Respond`. A record with no headers, so the answer allocates no more than the text.
event! : Worker.Event => Worker.Outcome
event! = |e| match e {
	Fetch(req) => {
		# `bench/worker.js` sends the text in the header `x-bench-text`, so a request has no wait before its work. A body
		# of `makeHandler` is a stream (PLAN.md 10a): one wait more (`handler-test.mjs`, `context-test.mjs`).
		text = match req.header("x-bench-text") {
			Ok(t) => t
			Err(_) => match req.body() {
				Bytes(b) => Str.from_utf8(b) ?? ""
				Text(s) => s
				Stream(_) => req.text!() ?? ""
				Empty => ""
			}
		}
		Respond(Response.from_status(200).with_body(Text(handle!(text))))
	}
	_ => Unhandled
}
