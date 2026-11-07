import Nullable

## The request of `POST /v1/compat` on the bot path (Registry R-AP10, R-AP66; Design Q154; slice 104d). Pure.
## The values (`result`, the id forms, the row limit) are checked by the Worker, not here (R-AP66 checks 5 and 6).
Compat :: [].{

	## One matrix row. All values are text as sent. `error_digest` is text or null (R-AP58).
	Row : { hash : Str, nightly : Str, target : Str, result : Str, error_digest : Try(Str, [None]) }

	## The sweep of a bot request (R-MX4): `upto_log_index` is the log index bound.
	Sweep : { nightly : Str, target : Str, upto_log_index : U64 }

	## The body: `rows` and the optional `sweep`.
	Post : { rows : List(Compat.Row), sweep : Try(Compat.Sweep, [None]) }

	## The wire forms. The `source` members exist only to find a `source` member (R-AP66: it is refused in the body and in a row).
	RowWire : { hash : Str, nightly : Str, target : Str, result : Str, error_digest : Nullable(Str), source : Try(Nullable(Str), [Missing]) }
	SweepWire : { nightly : Str, target : Str, upto_log_index : U64 }
	PostWire : { rows : List(Compat.RowWire), sweep : Try(Nullable(Compat.SweepWire), [Missing]), source : Try(Nullable(Str), [Missing]) }

	## Members in alphabetical order. `error_digest` is always written (`null` for none). `sweep` is left out for none. `source` is never written.
	encode_post : Compat.Post -> Str
	encode_post = |post| {
		wire : Compat.PostWire
		wire = {
			rows: post.rows.map(|r| { hash: r.hash, nightly: r.nightly, target: r.target, result: r.result, error_digest: Nullable.write(r.error_digest), source: Err(Missing) }),
			sweep: Nullable.write_opt(post.sweep.map_ok(|w| { nightly: w.nightly, target: w.target, upto_log_index: w.upto_log_index })),
			source: Err(Missing),
		}
		Json.to_str(wire)
	}

	## R-AP66, R-AP51, R-AP44. A missing `rows`, a missing or null `hash`, `nightly`, `target`, `result`, a missing `error_digest`, a `source` member (any value, also with an escaped key) in the body or in a row, and an `upto_log_index` that is not a U64 are `BadJson`. A `null` `error_digest` is `Err(None)`. An unknown member is ignored.
	decode_post : Str -> Try(Compat.Post, [BadJson(Str)])
	decode_post = |text| {
		parsed : Try(Compat.PostWire, _)
		parsed = Json.parse(text)
		match parsed {
			Err(e) => Err(BadJson(Str.inspect(e)))
			Ok(w) => {
				if (w.source.is_ok()) return Err(BadJson("member source is not allowed in the body"))
				if (w.rows.any(|r| r.source.is_ok())) return Err(BadJson("member source is not allowed in a row"))
				Ok({
					rows: w.rows.map(|r| { hash: r.hash, nightly: r.nightly, target: r.target, result: r.result, error_digest: Nullable.read(r.error_digest) }),
					sweep: Nullable.read_opt(w.sweep),
				})
			}
		}
	}

	## Slice 104f. One fact of a publish body (R-AP71): a bot row without `hash`. All values are text as sent. `error_digest` is text or null (R-AP58).
	Fact : { nightly : Str, target : Str, result : Str, error_digest : Try(Str, [None]) }

	## The body of `POST /v1/releases` (R-AP8, R-AP71): the asset URL and the optional facts. `compat` is `Err(None)` for a missing member or `null` (R-AP51).
	Publish : { url : Str, compat : Try(List(Compat.Fact), [None]) }

	## Slice 104f (R-AP72). One row of a user hint (R-CT2): no `error_digest`, no `source`. Texts as sent.
	HintRow : { hash : Str, nightly : Str, target : Str, result : Str }

	## The user hint request. `talon_version` is any text (R-CT12). Both members are required, also for `rows: []` (Design Q172).
	HintPost : { talon_version : Str, rows : List(Compat.HintRow) }

	## A skipped row (R-CT14): `row` is the index in the request, from 0. `reason` is text (a new reason is not an error for a reader).
	HintSkip : { row : U64, reason : Str }

	## The answer of a user hint (R-AP10, R-AP72): `written`, `first`, `skipped`.
	HintAnswer : { written : U64, first : U64, skipped : List(Compat.HintSkip) }

	## The answer of the bot path (R-AP10): `{"written":<n>}`.
	Written : { written : U64 }

	## The wire forms of 104f. The members `hash`, `source`, `error_digest` and `sweep` of the refused forms exist only to find them.
	FactWire : { nightly : Str, target : Str, result : Str, error_digest : Nullable(Str), hash : Try(Nullable(Str), [Missing]), source : Try(Nullable(Str), [Missing]) }
	PublishWire : { url : Str, compat : Try(Nullable(List(Compat.FactWire)), [Missing]) }
	HintRowWire : { hash : Str, nightly : Str, target : Str, result : Str, error_digest : Try(Nullable(Str), [Missing]), source : Try(Nullable(Str), [Missing]) }
	HintPostWire : { talon_version : Str, rows : List(Compat.HintRowWire), sweep : Try(Nullable(Str), [Missing]), source : Try(Nullable(Str), [Missing]) }

	## R-AP71. Members in alphabetical order (`compat`, `url`). A fact writes `error_digest` always (`null` for none). `compat` is left out for `Err(None)`; `Ok([])` is written as `[]`.
	encode_publish : Compat.Publish -> Str
	encode_publish = |p| {
		wire : Compat.PublishWire
		wire = {
			url: p.url,
			compat: Nullable.write_opt(p.compat.map_ok(|fs| fs.map(|f| { nightly: f.nightly, target: f.target, result: f.result, error_digest: Nullable.write(f.error_digest), hash: Err(Missing), source: Err(Missing) }))),
		}
		Json.to_str(wire)
	}

	## R-AP71, R-AP51, R-MX5. `url` is required. `compat` missing or `null` is `Err(None)`. A fact with a missing `nightly`, `target`, `result` or `error_digest`, or with a member `hash` or `source` (any value, `null` too, also an escaped key), is `BadJson`. An unknown member is ignored.
	decode_publish : Str -> Try(Compat.Publish, [BadJson(Str)])
	decode_publish = |text| {
		parsed : Try(Compat.PublishWire, _)
		parsed = Json.parse(text)
		match parsed {
			Err(e) => Err(BadJson(Str.inspect(e)))
			Ok(w) => {
				facts = Nullable.read_opt(w.compat)
				if (facts.map_ok(|fs| fs.any(|f| f.hash.is_ok() or f.source.is_ok())) == Ok(Bool.True)) return Err(BadJson("member hash or source is not allowed in a fact"))
				Ok({ url: w.url, compat: facts.map_ok(|fs| fs.map(|f| { nightly: f.nightly, target: f.target, result: f.result, error_digest: Nullable.read(f.error_digest) })) })
			}
		}
	}

	## R-AP72. Members in alphabetical order (`rows`, `talon_version`).
	encode_hint_post : Compat.HintPost -> Str
	encode_hint_post = |p| {
		wire : Compat.HintPostWire
		wire = {
			rows: p.rows.map(|r| { hash: r.hash, nightly: r.nightly, target: r.target, result: r.result, error_digest: Err(Missing), source: Err(Missing) }),
			talon_version: p.talon_version,
			sweep: Err(Missing),
			source: Err(Missing),
		}
		Json.to_str(wire)
	}

	## R-AP72, R-AP70 row 6. `talon_version` and `rows` are required. `error_digest` in a row, `sweep`, and `source` in the body or in a row, with any value, `null` too, are `BadJson`. An unknown member is ignored.
	decode_hint_post : Str -> Try(Compat.HintPost, [BadJson(Str)])
	decode_hint_post = |text| {
		parsed : Try(Compat.HintPostWire, _)
		parsed = Json.parse(text)
		match parsed {
			Err(e) => Err(BadJson(Str.inspect(e)))
			Ok(w) => {
				if (w.sweep.is_ok() or w.source.is_ok()) return Err(BadJson("member sweep or source is not allowed in a hint request"))
				if (w.rows.any(|r| r.error_digest.is_ok() or r.source.is_ok())) return Err(BadJson("member error_digest or source is not allowed in a hint row"))
				Ok({ talon_version: w.talon_version, rows: w.rows.map(|r| { hash: r.hash, nightly: r.nightly, target: r.target, result: r.result }) })
			}
		}
	}

	## R-AP72: `{"written":<n>,"first":<k>,"skipped":[{"row":<i>,"reason":"<reason>"},...]}`. The members and the item members are in this order (not alphabetical). `skipped` is always there.
	encode_hint_answer : Compat.HintAnswer -> Str
	encode_hint_answer = |a| {
		item = |k| {
			reason : Str
			reason = Json.to_str(k.reason)
			"{\"row\":${k.row.to_str()},\"reason\":${reason}}"
		}
		items = Str.join_with(a.skipped.map(item), ",")
		"{\"written\":${a.written.to_str()},\"first\":${a.first.to_str()},\"skipped\":[${items}]}"
	}

	## R-AP72, R-AP51: all three members are required. The reader ignores the order and unknown members.
	decode_hint_answer : Str -> Try(Compat.HintAnswer, [BadJson(Str)])
	decode_hint_answer = |text| {
		parsed : Try(Compat.HintAnswer, _)
		parsed = Json.parse(text)
		parsed.map_err(|e| BadJson(Str.inspect(e)))
	}

	encode_written : Compat.Written -> Str
	encode_written = |w| Json.to_str(w)

	decode_written : Str -> Try(Compat.Written, [BadJson(Str)])
	decode_written = |text| {
		parsed : Try(Compat.Written, _)
		parsed = Json.parse(text)
		parsed.map_err(|e| BadJson(Str.inspect(e)))
	}
}
