app [event!] { pf: platform "../pf/main.roc" }

## research/alloc/foreign/heavy: one heavy, long-lived task per request. The build script copies this file next to a
## variant platform (`../pf/main.roc`). Query:
## | Name | Default | Use |
## | --- | --- | --- |
## | kb | 5120 | live bytes to build (string bytes + list bytes), in KB |
## | chunk | 256 | KB built between two waits (the build is in chunks, so tasks interleave) |
## | waits | 4 | waits while all of it is held |
## | ms | 50 | ms of each wait |
## | mix | s | s: strings of 12..63 B; b: 200..1999 B; l: 2100..8099 B; m: 3 of 4 small, 1 of 4 big |
## | grow | 512 | U64 items appended one by one to a list in each chunk (realloc growth) |
## | keep | 16 | keep 1 item of `keep` after the hold, then one more wait |
## | seed | 1 | seed of the lengths |
import pf.Worker
import pf.Request
import pf.Response
import pf.Time

Item : { i : U64, s : Str }
Chunk : { items : List(Item), nums : List(U64) }

num : Request, Str, U64 -> U64
num = |req, name, d| match req.query(name) {
	Ok(t) => U64.from_str(t) ?? d
	Err(_) => d
}

next : U64 -> U64
next = |x| x.times_wrap(6364136223846793005).plus_wrap(1442695040888963407)

## The length of item `r` (a random U64) for mix `mix`.
len_of : Str, U64 -> U64
len_of = |mix, r| {
	h = r // 8589934592
	small = 12 + h % 52
	big = 200 + h % 1800
	large = 2100 + h % 6000
	if mix == "b" big else if mix == "l" large else if mix == "m" (if h % 4 == 0 big else small) else small
}

## One chunk of about `bytes` bytes. Returns the chunk, the bytes and the next seed.
chunk : Str, U64, U64, U64, U64 -> (Chunk, U64, U64)
chunk = |mix, bytes, grow, first, seed0| {
	var $items = []
	var $seed = seed0
	var $got = 0
	var $i = first
	while $got < bytes {
		$seed = next($seed)
		n = len_of(mix, $seed)
		$items = $items.append({ i: $i, s: "x".repeat(n) })
		$got = $got + n + 20
		$i = $i + 1
	}
	var $nums = []
	var $k = 0
	while $k < grow {
		$nums = $nums.append($k)
		$k = $k + 1
	}
	({ items: $items, nums: $nums }, $got + grow * 8, $seed)
}

size : List(Chunk) -> U64
size = |cs| cs.fold(0, |acc, c| c.items.fold(acc + c.nums.len() * 8, |a, it| a + it.s.count_utf8_bytes() + 20))

heavy! : Request => Response
heavy! = |req| {
	kb = num(req, "kb", 5120)
	chunk_kb = num(req, "chunk", 256)
	waits = num(req, "waits", 4)
	ms = num(req, "ms", 50)
	grow = num(req, "grow", 512)
	keep = num(req, "keep", 16)
	mix = req.query("mix") ?? "s"
	var $seed = num(req, "seed", 1)
	var $data = []
	var $built = 0
	var $first = 0
	while $built < kb * 1024 {
		(c, b, s) = chunk(mix, chunk_kb * 1024, grow, $first, $seed)
		$seed = s
		$first = $first + c.items.len()
		$data = $data.append(c)
		$built = $built + b
		Time.sleep!(1)
	}
	var $w = 0
	while $w < waits {
		Time.sleep!(ms)
		$w = $w + 1
	}
	held = size($data)
	kept = $data.map(|c| { items: c.items.keep_if(|it| it.i % keep == 0), nums: [] })
	$data = []
	Time.sleep!(ms)
	left = size(kept)
	Response.from_text(200, "held ${held.to_str()} kept ${left.to_str()} chunks ${kept.len().to_str()}")
}

fetch! : Request => Try(Response, _)
fetch! = |req| Ok(heavy!(req))

worker = Worker.new({ fetch!: fetch!, bindings: [] })

event! = |e| worker.event!(e)
