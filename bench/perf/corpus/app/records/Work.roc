import Nullable

## The answer of `GET /v1/sweeps/{tag}` (Registry R-AP39, R-AP73; Design Q575; slice 104k). Pure.
Work :: [].{

	## The `sweeps` row of the nightly (target `any`): `{nightly, target, time, upto_log_index}`. It has `time` (ms, R-AP50), so it is not `Compat.Sweep` (the request form of R-AP10 has no `time`).
	Sweep : { nightly : Str, target : Str, time : U64, upto_log_index : U64 }

	## R-AP39: `sweep` is the row or `null` (`Err(None)`), `log_size` the log size now, `members` the count of members of the bot set, `missing` the hashes (base58) of the members with no `bot` row, in the order given.
	Answer : { sweep : Try(Work.Sweep, [None]), log_size : U64, members : U64, missing : List(Str) }

	## The wire form: `sweep` is required and can be `null`.
	Wire : { sweep : Nullable(Work.Sweep), log_size : U64, members : U64, missing : List(Str) }

	## Members in alphabetical order (`log_size`, `members`, `missing`, `sweep`), `sweep` always written (`null` for none). No white space.
	encode : Work.Answer -> Str
	encode = |answer| {
		wire : Work.Wire
		wire = { sweep: Nullable.write(answer.sweep), log_size: answer.log_size, members: answer.members, missing: answer.missing }
		Json.to_str(wire)
	}

	## R-AP51, R-AP73. All 4 members are required. A missing member or a wrong type is `BadJson`. `sweep: null` is `Err(None)`. An unknown member is ignored.
	decode : Str -> Try(Work.Answer, [BadJson(Str)])
	decode = |text| {
		parsed : Try(Work.Wire, _)
		parsed = Json.parse(text)
		match parsed {
			Err(e) => Err(BadJson(Str.inspect(e)))
			Ok(w) => Ok({ sweep: Nullable.read(w.sweep), log_size: w.log_size, members: w.members, missing: w.missing })
		}
	}
}
