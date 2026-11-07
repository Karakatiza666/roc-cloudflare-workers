## The answer of `GET /v1/compat_hints?audit=<n>` (Registry R-AP40, R-AP73; Design Q575; slice 104k). Pure.
Audit :: [].{

	## One pair with hints and no `bot` row. `hash` is base58, `nightly` the tag, `target` the name.
	Pair : { hash : Str, nightly : Str, target : Str, pass_count : U64, fail_count : U64, crash_count : U64 }

	## R-AP40: `{"pairs":[..]}`.
	Answer : { pairs : List(Audit.Pair) }

	## Members of the answer and of a pair in alphabetical order (`crash_count`, `fail_count`, `hash`, `nightly`, `pass_count`, `target`). The pairs stay in the order given. No white space.
	encode : Audit.Answer -> Str
	encode = |answer| Json.to_str(answer)

	## R-AP51, R-AP73. `pairs` and all 6 members of a pair are required. A missing member or a wrong type is `BadJson`. An unknown member is ignored.
	decode : Str -> Try(Audit.Answer, [BadJson(Str)])
	decode = |text| {
		parsed : Try(Audit.Answer, _)
		parsed = Json.parse(text)
		match parsed {
			Err(e) => Err(BadJson(Str.inspect(e)))
			Ok(a) => Ok(a)
		}
	}
}
