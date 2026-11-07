## The pure part of `GET /v1/packages?short=` and `?q=` (Registry 4.3: R-AP7, R-SN1 to R-SN5, R-AP33, R-AP46, R-TP11, R-TP14; slice 107). No effect, no platform import.
## The effects (the D1 session and its one call, the Cache API, the clock, the headers) are in `worker/ShortRoutes.roc`.
## The tests are in `worker/tests/unit/ShortsTest.roc` (W0) and `worker/tests/cases/shorts/` (W2).
## The texts of the `detail` of a problem and the members of the answer that the design does not give are proposals (TW24): `docs/slices/107-short-names.md` section 6.
## Every body is built here as text, so that two answers of one state have the same bytes and the same ETag (R-AP24, R-AP53, R-AP54).
import records.Sorted
import records.Artifact
import records.Short
import Problem

Shorts :: [].{

	## R-AP46, R-SN1: at most this many `short` values in one request (first guess).
	short_limit : U64
	short_limit = 50

	## R-SN5: at most this many packages in the answer of `?q=` (first guess).
	search_limit : U64
	search_limit = 20

	## R-AP7: the `Cache-Control` of a 200 answer and of a 304 answer of `?short=`.
	short_cache_control : Str
	short_cache_control = "max-age=60"

	## R-AP7: the `Cache-Control` of a 200 answer and of a 304 answer of `?q=`.
	search_cache_control : Str
	search_cache_control = "max-age=300"

	# ---- the query (R-AP7, R-AP46, R-AP48 rows 4 and 6) ----

	## `Short(values)`: one or more `short` parameters, in the order of the URL, each percent-decoded by the platform (`Request.query_all`: `+` is a space, a bad escape stays, bad UTF-8 is U+FFFD, Q442),
	## and not changed in any other way (the case fold is in `is_match`). `Search(text)`: the one `q` parameter, decoded.
	Query : [Short(List(Str)), Search(Str)]

	## `Bad(problem)`: 400 `bad-request`. `TooMany(count)`: 413 `too-large`, `count` is the number of `short` parameters (R-AP46).
	Refusal : [Bad(Problem), TooMany(U64)]

	## The checks of R-AP48 rows 4 and 6, in this order. The route makes no D1 call when one fails. The input is the values of `Request.query_all("short")` and `Request.query_all("q")`,
	## in request order (R-SN6: the form is the repeated parameter, a request has up to 50 `short` values). The platform does the parse and the decode; this function only decides.
	## 1. More than `short_limit` `short` parameters (an empty value counts): `Err(TooMany(count))`. This is before every 400 (R-AP48 row 4 before row 6).
	## 2. The 400 checks of R-SN7, `Err(Bad(Problem.new(BadRequest, detail)))`, in this order (the texts are proposals, TW24):
	##    `short` and `q` together: `the query parameters short and q must not be used together`;
	##    a `short` value that is empty: `the query parameter short must not be empty`;
	##    `q` more than once: `the query parameter q must not be given more than once`;
	##    an empty `q`: `the query parameter q must not be empty`;
	##    no `short` and no `q`: `GET /v1/packages needs the query parameter short or q`.
	## An unknown parameter is ignored (R-AP44).
	parse_query : List(Str), List(Str) -> Try(Shorts.Query, Shorts.Refusal)
	parse_query = |shorts, qs| {
		count = shorts.len()
		if count > short_limit {
			Err(TooMany(count))
		} else if count > 0 and !qs.is_empty() {
			bad("the query parameters short and q must not be used together")
		} else if shorts.any(|v| v == "") {
			bad("the query parameter short must not be empty")
		} else if qs.len() > 1 {
			bad("the query parameter q must not be given more than once")
		} else {
			match qs {
				[""] => bad("the query parameter q must not be empty")
				[q] => Ok(Search(q))
				_ => if (count > 0) Ok(Short(shorts)) else bad("GET /v1/packages needs the query parameter short or q")
			}
		}
	}

	bad : Str -> Try(Shorts.Query, Shorts.Refusal)
	bad = |detail| Err(Bad(Problem.new(BadRequest, detail)))

	## R-AP46: the body of the 413 answer, `application/problem+json`: the members `type` (`/errors/too-large`), `title`, `status` (413), `detail`,
	## `field` (`short`) and `limit` (50). `detail`: `the query has <count> short values, the limit is 50`. No white space.
	too_large_json : U64 -> Str
	too_large_json = |count| {
		detail = "the query has ${count.to_str()} short values, the limit is ${short_limit.to_str()}"
		Problem.to_json_with(Problem.new(TooLarge, detail), { field: "short", limit: short_limit })
	}

	# ---- the match rule (R-SN1, R-SN3) ----

	## R-SN1: the short keys of an `owner/repo` name: the repo name (the text after the first `/`) in lower case, and the repo name minus ONE leading `roc-`
	## when it has that prefix and something after it. Only ASCII letters change case. The repo name comes first. `lukewilliamboswell/roc-parser` gives
	## `["roc-parser", "parser"]`, `o/Parser` gives `["parser"]`, `o/roc-roc-x` gives `["roc-roc-x", "roc-x"]`, `o/rocx` gives `["rocx"]`, `o/roc-` gives `["roc-"]`.
	## A text with no `/` gives `[]`.
	short_keys : Str -> List(Str)
	short_keys = |name| match name.split_first("/") {
		Err(_) => []
		Ok({ after, .. }) => {
			repo = after.with_ascii_lowercased()
			if repo.starts_with("roc-") and repo.count_utf8_bytes() > 4 {
				[repo, repo.drop_prefix("roc-")]
			} else {
				[repo]
			}
		}
	}

	## R-SN1: the `short` value equals one key of the name, ASCII case-insensitive (`Parser` and `PARSER` match `roc-lang/roc-parser`; a letter that is not ASCII is not folded).
	## The value is the whole text: `pars` does not match `roc-parser`, and a value with a `/` (a full name) matches nothing.
	is_match : Str, Str -> Bool
	is_match = |short, name| short_keys(name).contains(short.with_ascii_lowercased())

	# ---- the match set (R-SN1, R-SN2, R-AP33, R-TP11, R-TP14) ----

	## The state of a name (R-AP32, R-TP11).
	State : [Active, Missing, Moved]

	## The wire text of a state: `active`, `missing`, `moved`.
	state_text : Shorts.State -> Str
	state_text = |state| match state {
		Active => "active"
		Missing => "missing"
		Moved => "moved"
	}

	## The state from the column `repos.state`: 0 `Active`, 1 `Missing`, 2 `Moved`. Another code is `Err(BadRow)`.
	state_of_code : I64 -> Try(Shorts.State, [BadRow(Str)])
	state_of_code = |code| match code {
		0 => Ok(Active)
		1 => Ok(Missing)
		2 => Ok(Moved)
		_ => Err(BadRow("repos.state ${code.to_str()} is not a state"))
	}

	## A row that the statement of the route gives: one for each `repos` row that can matter. The statement reads (a) the names that may match (a superset of the match set
	## is good, `is_match` is the rule), and (b) the names on their successor chain (the recursive CTE of R-AP41 row 1). `name`: `names.value` (kind 3).
	## `state`: the code of `repos.state`. `successor`: the name of the successor, or `Missing`. `first_log_index`: the smallest `releases.log_index` of the name,
	## or `Missing` when the name has no release (a name on a chain can have none).
	Row : { name : Str, state : I64, successor : Try(Str, [Missing]), first_log_index : Try(U64, [Missing]) }

	## One package of the match set (R-SN1). `moved_from`: the old name, when the item stands for a name in the state `moved` (R-AP33).
	Item : { name : Str, first_log_index : U64, state : Shorts.State, moved_from : Try(Str, [None]) }

	## The matches of one `short` value, as the request wrote it.
	Entry : { short : Str, matches : List(Shorts.Item) }

	## R-TP14, R-AP33: the end of the successor chain of `name` in `rows`. A name whose `state` is not `Moved`, or that has no successor, is its own end.
	## R-SN8: the walk goes to the successor while the current name is `Moved`, fewer than 4 links are taken, and the successor is not yet on the walk.
	## So 5 links give the name after 4 links (state `Moved`), A to B to A from A gives B, A to B to C to A from A gives C, a name whose successor is itself is its own end,
	## and a `Missing` name ends the walk. A successor name that is not in `rows` ends the walk at the last name in `rows`.
	chain_end : Str, List(Shorts.Row) -> Str
	chain_end = |name, rows| walk(name, [name], 0, rows)

	walk : Str, List(Str), U64, List(Shorts.Row) -> Str
	walk = |current, seen, links, rows| match find_row(rows, current) {
		Err(_) => current
		Ok(row) => match row.successor {
			Ok(next) if row.state == 2 and links < 4 and !seen.contains(next) and find_row(rows, next).is_ok() => walk(next, seen.append(next), links + 1, rows)
			_ => current
		}
	}

	find_row : List(Shorts.Row), Str -> Try(Shorts.Row, [NotFound])
	find_row = |rows, name| rows.find_first(|r| r.name == name)

	## The smallest of the log indexes that exist.
	smallest : List(Try(U64, [Missing])) -> U64
	smallest = |indexes| indexes.keep_oks(|i| i).fold(18446744073709551615, |a, b| if (b < a) b else a)

	## The answer for the `short` values, one entry for each value, in the order of the request (also two equal values: two entries). `rows` as for `Row`.
	## For a value `v`, the matched rows are those with `is_match(v, name)` and with `first_log_index` not `Missing` (R-SN2: an indexed package is a name with at least one release,
	## also yanked or withdrawn; a name in the state `missing` counts; a name with no release does not).
	## Each matched row becomes one item (R-AP33):
	## - state `Active` or `Missing`: `{name, first_log_index, state, moved_from: None}`.
	## - state `Moved`: the item of `chain_end(name, rows)`: its `name`, its `state` (the state of the end row), `moved_from: Ok(old name)`.
	##   R-SN9: its `first_log_index` is the smallest of the end row (when it has a release) and of each old name that it replaces in this entry. Names on the chain that are
	##   not in the set do not count. An end with no release still gives the item.
	## The set has an end once (R-AP33, R-SN9): when matched rows give one name, the item has `moved_from` (the smallest old name by bytes when there are several), also when the end is
	## itself in the set, and `first_log_index` is the smallest over the end and the old names. A moved name whose end is itself is not a replace: the item is the name, `Moved`, no `moved_from`.
	## The items are sorted by `name` (bytes). The compare is not ranked and not cut (R-SN1). A state code that is no state is `Err(BadRow)`.
	entries_of : List(Str), List(Shorts.Row) -> Try(List(Shorts.Entry), [BadRow(Str)])
	entries_of = |shorts, rows| shorts.map_try(
		|short| {
			matched = rows.keep_if(|r| is_match(short, r.name) and r.first_log_index.is_ok())
			bound = matched.map_try(|r| state_of_code(r.state))?
			_ = bound
			pairs = matched.map(|r| (r, target_of(r, rows)))
			ends = sorted_names(pairs.map(|t| t.1))
			items = ends.map_try(|end| item_of(end, pairs, rows))?
			Ok({ short, matches: items })
		},
	)

	target_of : Shorts.Row, List(Shorts.Row) -> Str
	target_of = |row, rows| if (row.state == 2) chain_end(row.name, rows) else row.name

	sorted_names : List(Str) -> List(Str)
	sorted_names = |names| Sorted.sort_with(names, |a, b| Artifact.compare(a, b)).fold([], |acc, n| if (acc.contains(n)) acc else acc.append(n))

	## The item for one end: the end row and the old names (matched moved rows) that it replaces.
	item_of : Str, List((Shorts.Row, Str)), List(Shorts.Row) -> Try(Shorts.Item, [BadRow(Str)])
	item_of = |end, pairs, rows| {
		olds = pairs.keep_if(|t| t.1 == end and t.0.name != end).map(|t| t.0)
		end_row = find_row(rows, end) ?? { name: end, state: 0, successor: Err(Missing), first_log_index: Err(Missing) }
		state = state_of_code(end_row.state)?
		first = smallest(olds.map(|r| r.first_log_index).append(end_row.first_log_index))
		moved_from = match sorted_names(olds.map(|r| r.name)) {
			[old, ..] => Ok(old)
			[] => Err(None)
		}
		Ok({ name: end, first_log_index: first, state, moved_from })
	}

	## R-AP7, R-SN1, R-AP33: `{"matches":[<entry>,...]}`. An entry: `{"matches":[<item>,...],"short":"<value as sent>"}`. An item: `{"first_log_index":N,"moved_from":"..","name":"..","state":".."}`
	## with `moved_from` only when the item has it (R-AP51: an optional member with no value is left out). The members are in alphabetical order, no white space, text escaped as JSON.
	## No entry: `{"matches":[]}`.
	matches_body : List(Shorts.Entry) -> Str
	matches_body = |entries| Short.encode_matches({ matches: entries })

	# ---- the search (R-AP7, R-SN5) ----

	## A row that the statement of `?q=` gives: an indexed package (R-SN2) with its state and its smallest log index. `state` is the code.
	SearchRow : { name : Str, state : I64, first_log_index : U64 }

	## R-SN10: the names ranked by `text`, at most `search_limit`. `t` is `text` with the ASCII letters in lower case. A name is compared in lower case. Its repo part is the text after
	## the first `/`. Its short part is the repo part without a leading `roc-` when the repo part is longer than 4 bytes. Rank 1: the name, the repo part or the short part equals `t`.
	## Rank 2: one of them starts with `t`. Rank 3: the name has `t` inside. Else the name is not in the list (no fuzzy match, also when it has characters in common).
	## The order is the rank, then the name by bytes (the name as given). Cut to 20 after the order. The result is a function of `text` and `names` only.
	rank : Str, List(Str) -> List(Str)
	rank = |text, names| {
		t = text.with_ascii_lowercased()
		ranked = names.map(|n| (rank_of(t, n), n)).keep_if(|p| p.0 > 0)
		Sorted.sort_with(ranked, |a, b| if (a.0 < b.0) Before else if (a.0 > b.0) After else Artifact.compare(a.1, b.1)).take_first(search_limit).map(|p| p.1)
	}

	## 1 exact, 2 prefix, 3 substring of the name, 0 no match (R-SN10).
	rank_of : Str, Str -> U64
	rank_of = |t, name| {
		full = name.with_ascii_lowercased()
		repo = match full.split_first("/") {
			Ok({ after, .. }) => after
			Err(_) => full
		}
		short = if (repo.starts_with("roc-") and repo.count_utf8_bytes() > 4) repo.drop_prefix("roc-") else repo
		parts = [full, repo, short]
		if parts.any(|p| p == t) {
			1
		} else if parts.any(|p| p.starts_with(t)) {
			2
		} else if full.contains(t) {
			3
		} else {
			0
		}
	}

	## R-AP7, R-SN6: `{"packages":[<item>,...]}` with the items of `rank` in its order, an item `{"first_log_index":N,"name":"..","state":".."}` (no `moved_from`, the state of the name itself,
	## also `moved`). No package: `{"packages":[]}`. A state code that is no state is `Err(BadRow)`.
	search_body : Str, List(Shorts.SearchRow) -> Try(Str, [BadRow(Str)])
	search_body = |text, rows| {
		names = rank(text, rows.map(|r| r.name))
		hits = names.keep_oks(|n| rows.find_first(|r| r.name == n)).map_try(
			|r| {
				state = state_of_code(r.state)?
				Ok({ name: r.name, first_log_index: r.first_log_index, state })
			},
		)?
		Ok(Short.encode_packages({ found: hits }))
	}
}
