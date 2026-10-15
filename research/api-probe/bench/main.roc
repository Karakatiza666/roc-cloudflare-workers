app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.29.0/GrSTLEKd6yw8orQ5ByQQVY3Htg59vZYaoHBvQELueiMB.tar.zst" }

import pf.Stdout
import pf.Utc
import Js
import Js2

## Decode cost in Roc of 200 D1 rows (API.md 12). Each case: 7 rounds of 300 decodes, the best round.
Row : { grp : Str, version : Str, hash : Str, url : Str, published_at : U64, log_index : U64, yanked : U64, provenance : Str }

row : U64 -> Row
row = |i| {
	h = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	{ grp: "roc-lang/http", version: "1.${i.to_str()}.0", hash: h, url: "https://github.com/roc-lang/http/releases/download/1.${i.to_str()}.0/${h}.tar.zst", published_at: 1760000000 + i, log_index: 184000 + i, yanked: 0, provenance: "{\"workflow\":\"release.yml\"}" }
}

as_js : Row -> Js
as_js = |r| Arr([Text(r.grp), Text(r.version), Text(r.hash), Text(r.url), Num(r.published_at.to_f64()), Num(r.log_index.to_f64()), Num(r.yanked.to_f64()), Text(r.provenance)])

from_js : Js -> Try(Row, [Shape])
from_js = |v| match v {
	Arr([Text(grp), Text(version), Text(hash), Text(url), Num(p), Num(l), Num(y), Text(provenance)]) =>
		Ok({ grp, version, hash, url, published_at: p.to_u64_try() ?? 0, log_index: l.to_u64_try() ?? 0, yanked: y.to_u64_try() ?? 0, provenance })
	_ => Err(Shape)
}

from_js2 : Js2 -> Try(Row, [Shape])
from_js2 = |v| match v {
	Arr([Text(grp), Text(version), Text(hash), Text(url), Num(p), Num(l), Num(y), Text(provenance)]) =>
		Ok({ grp, version, hash, url, published_at: p.to_u64_try() ?? 0, log_index: l.to_u64_try() ?? 0, yanked: y.to_u64_try() ?? 0, provenance })
	_ => Err(Shape)
}

reps : U64
reps = 300

## Best of 7 rounds, in ns per decode. `f!` returns 1 on success.
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
	# The count comes from the clock, so the compiler cannot fold the decodes.
	n = 200 + (Utc.now!() % 1).to_u64_wrap()
	rows : List(Row)
	rows = 0.U64.until(n).map(row).collect()
	bin = Js.encode(Arr(rows.map(as_js)))
	json = Json.to_str(rows)

	cases = [
		("Js bytes to a Js tree only", |_| if Js.decode(bin).is_ok() 1 else 0),
		("Js bytes to typed rows", |_| match Js.decode(bin) {
			Ok(Arr(items)) => if items.map_try(from_js).is_ok() 1 else 0
			_ => 0
		}),
		("Js bytes to typed rows, direct integer reads", |_| match Js2.decode(bin) {
			Ok(Arr(items)) => if items.map_try(from_js2).is_ok() 1 else 0
			_ => 0
		}),
		("JSON text to typed rows (Json.parse)", |_| {
			parsed : Try(List(Row), _)
			parsed = Json.parse(json)
			if parsed.is_ok() 1 else 0
		}),
	]
	Stdout.line!("200 rows: ${bin.len().to_str()} B as Js bytes, ${json.count_utf8_bytes().to_str()} B as JSON")?
	for case in cases {
		(name, f) = case
		r = best!(|x| f(x))
		Stdout.line!("${name}: ${(r.ns / 1000).to_str()} µs (ok ${r.ok.to_str()} of ${(7 * reps).to_str()})")?
	}
	Ok({})
}
