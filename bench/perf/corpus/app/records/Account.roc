import Nullable

## The types of the account routes (Registry R-AP35, R-AP37, R-CT8 to R-CT10, R-AP73; slice 104e). Pure. No Worker code uses them before slice 117.
## The member order of the encoders is the alphabetical order of the derived codec (a proposal, TW24: the Worker has no bytes for these yet). A time is milliseconds (R-AP50). The decoders follow R-AP51: all members are required (a time may be `null`), an unknown member is ignored.
Account :: [].{

	## `{id, login}`: the GitHub user id (an integer) and the login.
	Who : { id : U64, login : Str }

	## R-AP35 / R-CT10. `first_time` and `last_time` are `Err(None)` (null) for an account with no row.
	Tracker : {
		account : Account.Who,
		machines : U64,
		counted : U64,
		first : U64,
		agreed : U64,
		disagreed : U64,
		unconfirmed : U64,
		first_time : Try(U64, [None]),
		last_time : Try(U64, [None]),
	}

	## R-AP37 answer: the JWT of R-CT9, its expiry in milliseconds, the account.
	Token : { token : Str, expires_at : U64, account : Account.Who }

	## R-AP37 request: `{"github_token":".."}`.
	Login : { github_token : Str }

	TrackerWire : {
		account : Account.Who,
		machines : U64,
		counted : U64,
		first : U64,
		agreed : U64,
		disagreed : U64,
		unconfirmed : U64,
		first_time : Nullable(U64),
		last_time : Nullable(U64),
	}

	bad_json : _ -> [BadJson(Str)]
	bad_json = |e| BadJson(Str.inspect(e))

	encode_tracker : Account.Tracker -> Str
	encode_tracker = |t| {
		wire : Account.TrackerWire
		wire = {
			account: t.account,
			machines: t.machines,
			counted: t.counted,
			first: t.first,
			agreed: t.agreed,
			disagreed: t.disagreed,
			unconfirmed: t.unconfirmed,
			first_time: Nullable.write(t.first_time),
			last_time: Nullable.write(t.last_time),
		}
		Json.to_str(wire)
	}

	decode_tracker : Str -> Try(Account.Tracker, [BadJson(Str)])
	decode_tracker = |text| {
		parsed : Try(Account.TrackerWire, _)
		parsed = Json.parse(text)
		parsed.map_ok(|w| { account: w.account, machines: w.machines, counted: w.counted, first: w.first, agreed: w.agreed, disagreed: w.disagreed, unconfirmed: w.unconfirmed, first_time: Nullable.read(w.first_time), last_time: Nullable.read(w.last_time) }).map_err(bad_json)
	}

	encode_token : Account.Token -> Str
	encode_token = |t| Json.to_str(t)

	decode_token : Str -> Try(Account.Token, [BadJson(Str)])
	decode_token = |text| {
		parsed : Try(Account.Token, _)
		parsed = Json.parse(text)
		parsed.map_err(bad_json)
	}

	encode_login : Account.Login -> Str
	encode_login = |l| Json.to_str(l)

	decode_login : Str -> Try(Account.Login, [BadJson(Str)])
	decode_login = |text| {
		parsed : Try(Account.Login, _)
		parsed = Json.parse(text)
		parsed.map_err(bad_json)
	}
}
