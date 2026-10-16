app [handle!] { pf: platform "../platform/main.roc" }

import pf.Wait

## A package row of the registry, to make realistic heap data.
Item : { id : U64, name : Str, version : Str, summary : Str, tags : List(Str), downloads : U64, yanked : Bool }

## Kind 1: a fetch through the service binding (body: the echo).
fetch! : Str => Str
fetch! = |url| Str.from_utf8_lossy(Wait.wait!(1, 0, "GET", url, []).body)

## Kind 2: a "db" query.
db! : Str => Str
db! = |q| Str.from_utf8_lossy(Wait.wait!(2, 0, q, "", []).body)

items : Str, U64 -> List(Item)
items = |id, count| {
	var $out = List.with_capacity(count)
	for i in 0.U64.until(count) {
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
		good = if mine.tag.ends_with(id) 1 else 1000000
		{ sum: r.sum + mine.level * 1000 + mine.tag.count_utf8_bytes() + good, out: r.out }
	}
}

## Request: "<id> <trap: 0|1> <depth> <items> [dbg]". With `dbg`, the request writes 200 `dbg` lines
## after its waits and then crashes (`bench/log-test.mjs`). Body: "id=<id> json=<bytes> sum=<sum> fetch=<echo> db=<echo>".
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
	json = Json.to_str(items(id, count))
	r = deep!(depth, id, trap)
	if parts.get(4) == Ok("dbg") {
		for i in 0.U64.until(200) {
			dbg "request ${id} line ${i.to_str()}"
		}
		crash "crash after dbg of request ${id}"
	}
	"id=${id} json=${json.count_utf8_bytes().to_str()} sum=${r.sum.to_str()} ${r.out}"
}
