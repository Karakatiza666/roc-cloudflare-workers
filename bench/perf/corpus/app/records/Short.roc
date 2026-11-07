import Nullable

## The answers of `GET /v1/packages` (Registry R-AP7, R-SN1, R-SN6, R-AP33, R-AP73; slice 104e). Pure.
## The encoders write the bytes of `worker/lib/Shorts.roc` (`matches_body`, `search_body`): no white space, the members in alphabetical order. An item of `matches`: `first_log_index`, `moved_from` (left out for `Err(None)`), `name`, `state`. An entry: `matches`, `short`. An item of `packages`: `first_log_index`, `name`, `state`. The lists are in the order given.
## The decoders follow R-AP51: `moved_from` is optional (missing or `null` is `Err(None)`), all other members are required, a `state` outside `active`, `missing`, `moved` is `BadJson`, an unknown member is ignored.
Short :: [].{

	State : [Active, Missing, Moved]

	## An item of a match list (R-SN1, R-AP33). `moved_from` is the old name of a replaced name.
	Item : { name : Str, first_log_index : U64, state : Short.State, moved_from : Try(Str, [None]) }

	## An entry: the `short` value as sent and its matches (R-SN6).
	Entry : { short : Str, matches : List(Short.Item) }

	## `?short=` answer: `{"matches":[..]}`.
	Matches : { matches : List(Short.Entry) }

	## An item of the search answer (R-SN6): no `moved_from`.
	Hit : { name : Str, first_log_index : U64, state : Short.State }

	## `?q=` answer: `{"packages":[..]}`. `packages` is a reserved word in Roc, so the field is `found`; the wire member is `packages`. The codec does the rename (for example by a parse into a `Dict(Str, List(..))`, which reads an unknown member only when its value is a list of hits).
	Packages : { found : List(Short.Hit) }

	## The wire forms: the state is text, `moved_from` is optional (missing or `null` is none).
	ItemWire : { name : Str, first_log_index : U64, state : Str, moved_from : Try(Nullable(Str), [Missing]) }
	EntryWire : { short : Str, matches : List(Short.ItemWire) }
	MatchesWire : { matches : List(Short.EntryWire) }
	HitWire : { name : Str, first_log_index : U64, state : Str }

	state_text : Short.State -> Str
	state_text = |s| match s {
		Active => "active"
		Missing => "missing"
		Moved => "moved"
	}

	state_of : Str -> Try(Short.State, [BadJson(Str)])
	state_of = |text| match text {
		"active" => Ok(Active)
		"missing" => Ok(Missing)
		"moved" => Ok(Moved)
		other => Err(BadJson("unknown state ${other}"))
	}

	bad_json : _ -> [BadJson(Str)]
	bad_json = |e| BadJson(Str.inspect(e))

	encode_matches : Short.Matches -> Str
	encode_matches = |m| {
		wire : Short.MatchesWire
		wire = {
			matches: m.matches.map(
				|e| {
					short: e.short,
					matches: e.matches.map(|i| { name: i.name, first_log_index: i.first_log_index, state: state_text(i.state), moved_from: Nullable.write_opt(i.moved_from) }),
				},
			),
		}
		Json.to_str(wire)
	}

	decode_matches : Str -> Try(Short.Matches, [BadJson(Str)])
	decode_matches = |text| {
		parsed : Try(Short.MatchesWire, _)
		parsed = Json.parse(text)
		w = parsed.map_err(bad_json)?
		entries = w.matches.map_try(
			|e| {
				items = e.matches.map_try(|i| Ok({ name: i.name, first_log_index: i.first_log_index, state: state_of(i.state)?, moved_from: Nullable.read_opt(i.moved_from) }))?
				Ok({ short: e.short, matches: items })
			},
		)?
		Ok({ matches: entries })
	}

	encode_packages : Short.Packages -> Str
	encode_packages = |p| {
		hits = p.found.map(
			|h| {
				wire : Short.HitWire
				wire = { name: h.name, first_log_index: h.first_log_index, state: state_text(h.state) }
				Json.to_str(wire)
			},
		)
		"{\"packages\":[${Str.join_with(hits, ",")}]}"
	}

	decode_packages : Str -> Try(Short.Packages, [BadJson(Str)])
	decode_packages = |text| {
		parsed : Try(Dict(Str, List(Short.HitWire)), _)
		parsed = Json.parse(text)
		dict = parsed.map_err(bad_json)?
		hits = dict.get("packages").map_err(|_| BadJson("missing packages"))?
		found = hits.map_try(|h| Ok({ name: h.name, first_log_index: h.first_log_index, state: state_of(h.state)? }))?
		Ok({ found: found })
	}
}
