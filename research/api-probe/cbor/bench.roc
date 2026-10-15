app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.29.0/GrSTLEKd6yw8orQ5ByQQVY3Htg59vZYaoHBvQELueiMB.tar.zst" }

import pf.Stdout
import pf.Path
import pf.Utc
import Cbor
import CborRows

## Decode cost in Roc of 200 D1 rows into typed rows (API.md AQ8, AQ9). The input files come from
## cbor-test.mjs, so the bytes are what JS writes. Each case: 7 rounds of 300 decodes, the best round.
Row : { grp : Str, version : Str, hash : Str, url : Str, published_at : U64, log_index : U64, yanked : U64, provenance : Str }

RowTuple : (Str, Str, Str, Str, U64, U64, U64, Str)

reps : U64
reps = 300

best! : ({} => U64) => { ns : U128, ok : U64 }
best! = |f!| {
	var $best = 0.U128
	var $ok = 0.U64
	for r in 0.U64.until(7) {
		t0 = Utc.now!()
		for _ in 0.U64.until(reps) {
			$ok = $ok + f!({})
		}
		t = (Utc.now!() - t0) / reps.to_u128()
		$best = if r == 0 or t < $best t else $best
	}
	{ ns: $best, ok: $ok }
}

main! = |_args| {
	objects = Path.Utf8("rows.cbor").read_bytes!()?
	arrays = Path.Utf8("rows-arr.cbor").read_bytes!()?
	with_columns = Path.Utf8("rows-cols.cbor").read_bytes!()?
	json = Str.from_utf8(Path.Utf8("rows.json").read_bytes!()?) ? |_| BadUtf8

	cases = [
		("CBOR maps to typed records (Cbor.parse)", |_| {
			parsed : Try(List(Row), _)
			parsed = Cbor.parse(objects)
			if parsed.is_ok() 1 else 0
		}),
		("CBOR arrays to typed tuples (Cbor.parse)", |_| {
			parsed : Try(List(RowTuple), _)
			parsed = Cbor.parse(arrays)
			if parsed.is_ok() 1 else 0
		}),
		("CBOR [columns, ...arrays] to typed records (CborRows.parse_rows)", |_| {
			parsed : Try(List(Row), _)
			parsed = CborRows.parse_rows(with_columns)
			if parsed.is_ok() 1 else 0
		}),
		("JSON text to typed records (Json.parse)", |_| {
			parsed : Try(List(Row), _)
			parsed = Json.parse(json)
			if parsed.is_ok() 1 else 0
		}),
		("Typed records to JSON (Json.to_str), with the CBOR decode", |_| {
			parsed : Try(List(Row), _)
			parsed = Cbor.parse(objects)
			match parsed {
				Ok(rows) => Json.to_str(rows).count_utf8_bytes() // 1000
				Err(_) => 0
			}
		}),
		("Typed records to CBOR (Cbor.encode), with the CBOR decode", |_| {
			parsed : Try(List(Row), _)
			parsed = Cbor.parse(objects)
			match parsed {
				Ok(rows) => Cbor.encode(rows).len() // 1000
				Err(_) => 0
			}
		}),
	]
	Stdout.line!("200 rows: ${objects.len().to_str()} B CBOR maps, ${arrays.len().to_str()} B CBOR arrays, ${json.count_utf8_bytes().to_str()} B JSON")?
	for case in cases {
		(name, f) = case
		r = best!(|x| f(x))
		Stdout.line!("${name}: ${(r.ns / 1000).to_str()} µs (ok ${r.ok.to_str()})")?
	}
	Ok({})
}
