app [event!] {
	pf: platform "../platform/main.roc",
	http: "https://github.com/roc-lang/http/releases/download/2.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	cbor_f: "../8g-cbor-field/main.roc",
	cbor_l: "../8g-cbor-first/main.roc",
}

## PLAN.md step 8g: the measure app. Each route runs one operation `n` times in one request (a loop with a changing
## input, so the compiler cannot hoist the work) and answers a short text with a checksum. The harness
## (`run-node.mjs`, `run-mf.mjs`) times the request for two values of `n` and divides the difference. `n=0` is the base.
## Routes: `/cross/<call|await>?k=` (a program of k ops), `/d1/<name>?rows=`, `/parse/<name>?rows=`, `/sha/<name>?size=`.
import pf.Worker
import pf.Request
import pf.Response
import pf.Js
import pf.Io
import pf.D1
import pf.WebCrypto
import pf.Cbor
import cbor_f.Cbor as CborF
import cbor_l.Cbor as CborL

import Q

Row : { grp : Str, version : Str, hash : Str, url : Str, published_at : U64, log_index : U64, yanked : U64, provenance : Str }

RowT : (Str, Str, Str, Str, U64, U64, U64, Str)

db = D1.binding("DB")

sql : Str
sql = "SELECT grp, version, hash, url, published_at, log_index, yanked, provenance FROM releases LIMIT ?"

fetch! : Request => Try(Response, _)
fetch! = |req| {
	n = Q.num(req, "n")
	k = Q.num(req, "k")
	rows = Q.num(req, "rows")
	size = Q.num(req, "size")
	text = match req.segments() {
		["cross", "call"] => cross!(n, k, Bool.False)
		["cross", "await"] => cross!(n, k, Bool.True)
		["cross", "build"] => cross_build(n, k)
		["d1", "all"] => d1_all!(n, rows)
		["d1", "rows"] => d1_rows!(n, rows)
		["d1", "all_tuples"] => d1_all_tuples!(n, rows)
		["d1", "js_only"] => d1_ops!(n, rows, JsOnly)
		["d1", "pack_only"] => d1_ops!(n, rows, PackOnly)
		["d1", "raw_js_only"] => d1_ops!(n, rows, RawJsOnly)
		["d1", "raw_only"] => d1_ops!(n, rows, RawOnly)
		["d1", "obj_tree"] => d1_ops!(n, rows, ObjTree)
		["d1", "all_arrays"] => d1_arrays!(n, rows)
		["d1", "tree_typed"] => d1_tree_typed!(n, rows)
		["parse", "records"] => parse!(n, rows, Records)
		["parse", "tuples"] => parse!(n, rows, Tuples)
		["parse", "fold_only"] => parse!(n, rows, FoldOnly)
		["parse", "variant_field"] => parse!(n, rows, VariantField)
		["parse", "variant_first"] => parse!(n, rows, VariantFirst)
		["sha", "wasm"] => sha_wasm!(n, size)
		["sha", "pick"] => sha_pick!(n, size)
		["sha", "digest"] => sha_digest!(n, size, FromWasm)
		["sha", "digest_js"] => sha_digest!(n, size, FromJs)
		["sha", "copy_only"] => sha_digest!(n, size, CopyOnly)
		_ => "no route"
	}
	Ok(Response.from_text(200, text))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)

# ---------------------------------------------------------------- one crossing

## `n` crossings of a program of `k` ops. One op: `isFinite(i)` on the `global` root, a plain JS function that is cheap.
## `i` changes, so each program is built again.
cross! : U64, U64, Bool => Str
cross! = |n, k, waits| {
	var $acc = 0.U64
	var $i = 0.U64
	while $i < n {
		op : Js.Op
		op = Call(Root("global"), "isFinite", [Lit(Int($i.to_i64_wrap()))])
		ops = List.repeat(op, k)
		r = if waits Io.await!(ops) else Io.call!(ops)
		match r {
			Ok(Bool(Bool.True)) => {
				$acc = $acc + 1
			}
			Ok(Undefined) => {
				$acc = $acc + 2
			}
			_ => {
				$acc = $acc + 1000
			}
		}
		$i = $i + 1
	}
	"cross ${n.to_str()} ${k.to_str()} ${$acc.to_str()}"
}

## `n` times the program of `k` ops is made as a `Js` tree (`Js.program`) and dropped: the Roc part of a crossing, no crossing.
cross_build : U64, U64 -> Str
cross_build = |n, k| {
	var $acc = 0.U64
	var $i = 0.U64
	while $i < n {
		op : Js.Op
		op = Call(Root("global"), "isFinite", [Lit(Int($i.to_i64_wrap()))])
		match Js.program(List.repeat(op, k)) {
			Arr(items) => {
				$acc = $acc + items.len()
			}
			_ => {
				$acc = $acc + 1000
			}
		}
		$i = $i + 1
	}
	"build ${n.to_str()} ${k.to_str()} ${$acc.to_str()}"
}

# ---------------------------------------------------------------- D1

limit_arg : Js.Arg
limit_arg = Lit(Int(100_000_000))

bound_ops : U64 -> List(Js.Op)
bound_ops = |rows| [
	Get(Root("env"), "DB"),
	Call(Slot(0), "prepare", [Lit(Text(sql))]),
	Call(Slot(1), "bind", [Lit(Int(rows.to_i64_wrap()))]),
]

D1Case : [JsOnly, PackOnly, RawJsOnly, RawOnly, ObjTree]

## The ops of `D1.all!` and `D1.rows!`, cut after the step that the case names (so the cost of each step is the
## difference of two cases). `JsOnly`: `all()` and no result. `PackOnly`: `all`, `results`, `pf.pack`, the bytes are
## counted and not parsed. `RawJsOnly`: `raw({ columnNames: true })` and no result. `RawOnly`: `raw`, `pf.limit`: the
## tree is decoded in Zig and counted, not matched.
d1_ops! : U64, U64, D1Case => Str
d1_ops! = |n, rows, which| {
	var $acc = 0.U64
	var $i = 0.U64
	while $i < n {
		b = bound_ops(rows)
		ops : List(Js.Op)
		ops = match which {
			JsOnly => b.concat([Call(Slot(2), "all", []), Fields(Slot(3), [])])
			PackOnly => b.concat([Call(Slot(2), "all", []), Get(Slot(3), "results"), Call(Root("pf"), "pack", [Slot(4), limit_arg])])
			RawJsOnly => b.concat([Call(Slot(2), "raw", [Lit(Obj([("columnNames", Bool(Bool.True))]))]), Fields(Slot(3), [])])
			RawOnly => b.concat([Call(Slot(2), "raw", [Lit(Obj([("columnNames", Bool(Bool.True))]))]), Call(Root("pf"), "limit", [Slot(3), limit_arg])])
			ObjTree => b.concat([Call(Slot(2), "all", []), Get(Slot(3), "results"), Call(Root("pf"), "limit", [Slot(4), limit_arg])])
		}
		match Io.await!(ops) {
			Ok(Packed(bytes)) => {
				$acc = $acc + bytes.len()
			}
			Ok(Arr(items)) => {
				$acc = $acc + items.len()
			}
			Ok(Obj(fields)) => {
				$acc = $acc + fields.len() + 1
			}
			other => crash "d1_ops!: ${Str.inspect(other)}"
		}
		$i = $i + 1
	}
	"d1 ${n.to_str()} ${rows.to_str()} ${$acc.to_str()}"
}

d1_all! : U64, U64 => Str
d1_all! = |n, rows| {
	var $acc = 0.U64
	var $i = 0.U64
	while $i < n {
		got : Try(List(Row), _)
		got = db.all!(sql, [Int(rows.to_i64_wrap())])
		match got {
			Ok(list) => {
				$acc = $acc + list.len() + sum_rows(list)
			}
			Err(e) => crash "d1_all!: ${Str.inspect(e)}"
		}
		$i = $i + 1
	}
	"d1 ${n.to_str()} ${rows.to_str()} ${$acc.to_str()}"
}

## PLAN.md 8g P1: `D1.all_tuples!` of the platform into `List(RowT)`. The answer equals the one of `d1_all!` (the same sum).
d1_all_tuples! : U64, U64 => Str
d1_all_tuples! = |n, rows| {
	var $acc = 0.U64
	var $i = 0.U64
	while $i < n {
		got : Try(List(RowT), _)
		got = db.all_tuples!(sql, [Int(rows.to_i64_wrap())])
		match got {
			Ok(list) => {
				$acc = $acc + list.len() + sum_tuples(list)
			}
			Err(e) => crash "d1_all_tuples!: ${Str.inspect(e)}"
		}
		$i = $i + 1
	}
	"d1 ${n.to_str()} ${rows.to_str()} ${$acc.to_str()}"
}

d1_rows! : U64, U64 => Str
d1_rows! = |n, rows| {
	var $acc = 0.U64
	var $i = 0.U64
	while $i < n {
		match db.rows!(sql, [Int(rows.to_i64_wrap())]) {
			Ok(r) => {
				$acc = $acc + r.rows.len() + r.columns.len()
			}
			Err(e) => crash "d1_rows!: ${Str.inspect(e)}"
		}
		$i = $i + 1
	}
	"d1 ${n.to_str()} ${rows.to_str()} ${$acc.to_str()}"
}

## A typed read of rows as arrays: `raw()` and `pf.pack` in JS, then `Cbor.parse` into tuples (what `D1.all!` could do if
## the type were a tuple, and the rows came as arrays).
d1_arrays! : U64, U64 => Str
d1_arrays! = |n, rows| {
	var $acc = 0.U64
	var $i = 0.U64
	while $i < n {
		bytes = packed!(rows, Bool.False)
		parsed : Try(List(RowT), _)
		parsed = Cbor.parse_with(bytes, { fields: Snake, int_from_text: Bool.True })
		match parsed {
			Ok(list) => {
				$acc = $acc + sum_tuples(list)
			}
			Err(e) => crash "d1_arrays!: ${Str.inspect(e)}"
		}
		$i = $i + 1
	}
	"d1 ${n.to_str()} ${rows.to_str()} ${$acc.to_str()}"
}

## The floor of a typed read through a `Js` tree: `raw({ columnNames: true })` and `pf.limit` (the tree is decoded in Zig, as
## `D1.rows!`), then a hand-written match of each row into a `Row` (no column names, the order is fixed). A generic typed read
## through a tree cannot be cheaper than this.
d1_tree_typed! : U64, U64 => Str
d1_tree_typed! = |n, rows| {
	var $acc = 0.U64
	var $i = 0.U64
	while $i < n {
		b = bound_ops(rows)
		ops : List(Js.Op)
		ops = b.concat([Call(Slot(2), "raw", [Lit(Obj([("columnNames", Bool(Bool.True))]))]), Call(Root("pf"), "limit", [Slot(3), limit_arg])])
		match Io.await!(ops) {
			Ok(Arr([_names, .. as items])) => {
				list = items.map(row_of_js)
				$acc = $acc + sum_rows(list)
			}
			other => crash "d1_tree_typed!: ${Str.inspect(other)}"
		}
		$i = $i + 1
	}
	"d1 ${n.to_str()} ${rows.to_str()} ${$acc.to_str()}"
}

row_of_js : Js -> Row
row_of_js = |item| match item {
	Arr([Text(grp), Text(version), Text(hash), Text(url), Int(published_at), Int(log_index), Int(yanked), Text(provenance)]) => {
		grp,
		version,
		hash,
		url,
		published_at: published_at.to_u64_wrap(),
		log_index: log_index.to_u64_wrap(),
		yanked: yanked.to_u64_wrap(),
		provenance,
	}
	_ => crash "row_of_js: ${Str.inspect(item)}"
}

# ---------------------------------------------------------------- Cbor.parse in wasm

ParseCase : [Records, Tuples, FoldOnly, VariantField, VariantFirst]

## One crossing gets the CBOR bytes of `rows` rows (`all` then `pack` for maps, `raw` then `pack` for arrays). Then `n`
## parses of those bytes, in Roc only. Before each parse one byte of the first text is changed (a letter that depends
## on `i`), so the parse cannot be hoisted. The bytes stay unique, so the change is in place. The sum reads every field.
parse! : U64, U64, ParseCase => Str
parse! = |n, rows, which| {
	maps = packed!(rows, Bool.True)
	arrays = packed!(rows, Bool.False)
	# The first letter of the first text: after the array head (2 bytes) and the map head and the key `grp`, or the row head.
	var $maps = maps
	var $arrays = arrays
	var $acc = 0.U64
	var $i = 0.U64
	prebuilt : List(Row)
	prebuilt = match Cbor.parse_with(maps, { fields: Snake, int_from_text: Bool.True }) {
		Ok(list) => list
		Err(e) => crash "parse!: ${Str.inspect(e)}"
	}
	while $i < n {
		letter = 65 + ($i % 26).to_u8_wrap()
		match which {
			Records => {
				$maps = $maps.set(8, letter) ?? crash "parse!: no byte 8"
				parsed : Try(List(Row), _)
				parsed = Cbor.parse_with($maps, { fields: Snake, int_from_text: Bool.True })
				match parsed {
					Ok(list) => {
						$acc = $acc + sum_rows(list) + first_letter(list)
					}
					Err(e) => crash "parse!: ${Str.inspect(e)}"
				}
			}
			VariantField => {
				$maps = $maps.set(8, letter) ?? crash "parse!: no byte 8"
				parsed : Try(List(Row), _)
				parsed = CborF.parse_with($maps, { fields: Snake, int_from_text: Bool.True })
				match parsed {
					Ok(list) => {
						$acc = $acc + sum_rows(list) + first_letter(list)
					}
					Err(e) => crash "parse!: ${Str.inspect(e)}"
				}
			}
			VariantFirst => {
				$maps = $maps.set(8, letter) ?? crash "parse!: no byte 8"
				parsed : Try(List(Row), _)
				parsed = CborL.parse_with($maps, { fields: Snake, int_from_text: Bool.True })
				match parsed {
					Ok(list) => {
						$acc = $acc + sum_rows(list) + first_letter(list)
					}
					Err(e) => crash "parse!: ${Str.inspect(e)}"
				}
			}
			Tuples => {
				$arrays = $arrays.set(4, letter) ?? crash "parse!: no byte 4"
				parsed : Try(List(RowT), _)
				parsed = Cbor.parse_with($arrays, { fields: Snake, int_from_text: Bool.True })
				match parsed {
					Ok(list) => {
						$acc = $acc + sum_tuples(list) + first_letter_t(list)
					}
					Err(e) => crash "parse!: ${Str.inspect(e)}"
				}
			}
			FoldOnly => {
				# The fold of the sum over a list that was parsed once: the cost of the sum alone.
				$acc = $acc + sum_rows(prebuilt) + letter.to_u64()
			}
		}
		$i = $i + 1
	}
	"parse ${n.to_str()} ${rows.to_str()} ${$acc.to_str()} bytes ${maps.len().to_str()} ${arrays.len().to_str()}"
}

packed! : U64, Bool => List(U8)
packed! = |rows, maps| {
	b = bound_ops(rows)
	ops : List(Js.Op)
	ops = if maps {
		b.concat([Call(Slot(2), "all", []), Get(Slot(3), "results"), Call(Root("pf"), "pack", [Slot(4), limit_arg])])
	} else {
		b.concat([Call(Slot(2), "raw", []), Call(Root("pf"), "pack", [Slot(3), limit_arg])])
	}
	match Io.await!(ops) {
		Ok(Packed(bytes)) => bytes
		other => crash "packed!: ${Str.inspect(other)}"
	}
}

sum_rows : List(Row) -> U64
sum_rows = |list| list.fold(
	0,
	|acc, r| acc + r.published_at + r.log_index + r.yanked + r.grp.count_utf8_bytes() + r.version.count_utf8_bytes() + r.hash.count_utf8_bytes() + r.url.count_utf8_bytes() + r.provenance.count_utf8_bytes(),
)

sum_tuples : List(RowT) -> U64
sum_tuples = |list| list.fold(
	0,
	|acc, (grp, version, hash, url, published_at, log_index, yanked, provenance)| acc + published_at + log_index + yanked + grp.count_utf8_bytes() + version.count_utf8_bytes() + hash.count_utf8_bytes() + url.count_utf8_bytes() + provenance.count_utf8_bytes(),
)

## The first byte of the first `grp`: it shows that the changed byte was read.
first_letter : List(Row) -> U64
first_letter = |list| match list.first() {
	Ok(r) => r.grp.to_utf8().first().map_ok(|b| b.to_u64()) ?? 0
	Err(_) => 0
}

first_letter_t : List(RowT) -> U64
first_letter_t = |list| match list.first() {
	Ok((grp, _, _, _, _, _, _, _)) => grp.to_utf8().first().map_ok(|b| b.to_u64()) ?? 0
	Err(_) => 0
}

# ---------------------------------------------------------------- SHA-256

## `n` times `Crypto.SHA256.hash` of a buffer of `size` bytes in wasm (the first byte changes each time).
sha_wasm! : U64, U64 => Str
sha_wasm! = |n, size| {
	var $data = List.repeat(7, size)
	var $last = Crypto.SHA256.hash([])
	var $i = 0.U64
	while $i < n {
		$data = $data.set(0, $i.to_u8_wrap()) ?? $data
		$last = Crypto.SHA256.hash($data)
		$i = $i + 1
	}
	"sha ${n.to_str()} ${size.to_str()} ${if n == 0 "" else $last.to_hex()}"
}

## PLAN.md 8g P2: `n` times `WebCrypto.sha256!` of a buffer of `size` bytes (the builtin below 4,096 bytes, `digest` above).
sha_pick! : U64, U64 => Str
sha_pick! = |n, size| {
	var $data = List.repeat(7, size)
	var $last = List.repeat(0.U8, 0)
	var $i = 0.U64
	while $i < n {
		$data = $data.set(0, $i.to_u8_wrap()) ?? $data
		match WebCrypto.sha256!($data) {
			Ok(d) => {
				$last = d
			}
			Err(e) => crash "sha_pick!: ${Str.inspect(e)}"
		}
		$i = $i + 1
	}
	"sha ${n.to_str()} ${size.to_str()} ${if n == 0 "" else to_hex($last)}"
}

ShaCase : [FromWasm, FromJs, CopyOnly]

## `n` times `crypto.subtle.digest('SHA-256', buffer)` through one `await!`. `FromWasm`: the buffer is a `List(U8)` of wasm
## memory that crosses (`Lit(Bytes)`). `FromJs`: the buffer is made in JS (`ops.lib.buf(size)`, a cached array), so
## nothing is copied from wasm. `CopyOnly`: the bytes cross to `ops.lib.len`, no digest (the cost of the copy and the wait).
sha_digest! : U64, U64, ShaCase => Str
sha_digest! = |n, size, which| {
	var $data = List.repeat(7, size)
	var $last = List.repeat(0.U8, 0)
	var $i = 0.U64
	while $i < n {
		$data = $data.set(0, $i.to_u8_wrap()) ?? $data
		ops : List(Js.Op)
		ops = match which {
			FromWasm => [
				Get(Root("global"), "crypto"),
				Get(Slot(0), "subtle"),
				Call(Slot(1), "digest", [Lit(Text("SHA-256")), Lit(Bytes($data))]),
			]
			FromJs => [
				Get(Root("ops"), "lib"),
				Call(Slot(0), "buf", [Lit(Int(size.to_i64_wrap()))]),
				Get(Root("global"), "crypto"),
				Get(Slot(2), "subtle"),
				Call(Slot(3), "digest", [Lit(Text("SHA-256")), Slot(1)]),
			]
			CopyOnly => [
				Get(Root("ops"), "lib"),
				Call(Slot(0), "len", [Lit(Bytes($data))]),
			]
		}
		match Io.await!(ops) {
			Ok(Bytes(d)) => {
				$last = d
			}
			Ok(Int(len)) => {
				$last = [len.to_u8_wrap()]
			}
			other => crash "sha_digest!: ${Str.inspect(other)}"
		}
		$i = $i + 1
	}
	"sha ${n.to_str()} ${size.to_str()} ${if n == 0 "" else if which == FromWasm to_hex($last) else "-"}"
}

to_hex : List(U8) -> Str
to_hex = |bytes| {
	digit = |x| if x < 10 48 + x else 87 + x
	chars = bytes.join_map(|b| [digit(b // 16), digit(b % 16)])
	Str.from_utf8(chars) ?? ""
}
