import Artifact
import Code
import Nullable
import Release

## The closure query (Registry 4.1, R-AP3, R-AP15 to R-AP17, R-AP29, R-AP32). Pure.
## Optional members of the request (`series`, `range`, `compilers`, `from`, `to`) are left out of the JSON when they are absent (R-AP16), and read as absent when they are missing. A member that the type does not know is ignored (R-AP44).
Closure :: [].{

	## One group of the request (R-AP16). `group` is the URL form of R-AP15.
	GroupQuery : { group : Str, series : Try(Str, [None]), range : Try(Str, [None]) }

	## The window W of compilers, as tags (R-AP16). Each end is optional.
	Window : { from : Try(Str, [None]), to : Try(Str, [None]) }

	## The body of `POST /v1/closure` (R-AP16).
	Request : { groups : List(Closure.GroupQuery), hashes : List(Str), compilers : Try(Closure.Window, [None]) }

	## An epoch of the registry for one target (R-AP17 `epochs`). `from` and `to` are compiler tags.
	Epoch : { target : Str, from : Str, to : Str }

	## A run (R-AP17 `runs`). `error_digest` is text or `null` (R-AP58): a required member, written as `null` for none; an empty text is a digest. `target` is a target name, `source` and `result` have the lower-case wire text.
	Run : { hash : Str, target : Str, source : Code.Source, result : Code.Result, error_digest : Try(Str, [None]), from : Str, to : Str }

	## The nearest row before or after E (R-AP17 `nearest`). `side` is `before` or `after`.
	Nearest : { hash : Str, target : Str, source : Code.Source, result : Code.Result, error_digest : Try(Str, [None]), nightly : Str, side : [Before, After] }

	## A row of `hints` (R-AP17).
	Hint : { hash : Str, nightly : Str, target : Str, pass_count : U64, fail_count : U64, crash_count : U64 }

	## An item of `checked` (R-AP29). `checked_at` is a time in milliseconds (R-AP50), `Err(None)` (null) when never read.
	Checked : { name : Str, checked_at : Try(U64, [None]), stale : Bool }

	## An item of `repos` (R-AP32). `state` is `active`, `missing` or `moved` on the wire. `successor` is a name, `Err(None)` (null) for none. `state_at` is a time in milliseconds (R-AP50).
	Repo : { name : Str, state : [Active, Missing, Moved], successor : Try(Str, [None]), state_at : U64 }

	## The answer of `POST /v1/closure` (R-AP17), with `repos` of R-AP32.
	Answer : {
		artifacts : List(Artifact.Row),
		releases : List(Release.Row),
		epochs : List(Closure.Epoch),
		runs : List(Closure.Run),
		nearest : List(Closure.Nearest),
		hints : List(Closure.Hint),
		log_size : U64,
		unknown : List(Str),
		checked : List(Closure.Checked),
		repos : List(Closure.Repo),
	}

	## The wire forms. A nullable or optional member is `Try(Nullable(a), [Missing])`. A closed set is text.
	GroupWire : { group : Str, series : Try(Nullable(Str), [Missing]), range : Try(Nullable(Str), [Missing]) }
	WindowWire : { from : Try(Nullable(Str), [Missing]), to : Try(Nullable(Str), [Missing]) }
	RequestWire : { groups : List(Closure.GroupWire), hashes : List(Str), compilers : Try(Nullable(Closure.WindowWire), [Missing]) }
	RunWire : { hash : Str, target : Str, source : Str, result : Str, error_digest : Nullable(Str), from : Str, to : Str }
	NearestWire : { hash : Str, target : Str, source : Str, result : Str, error_digest : Nullable(Str), nightly : Str, side : Str }
	CheckedWire : { name : Str, checked_at : Nullable(U64), stale : Bool }
	RepoWire : { name : Str, state : Str, successor : Nullable(Str), state_at : U64 }
	AnswerWire : {
		artifacts : List(Artifact.Wire),
		releases : List(Release.Wire),
		epochs : List(Closure.Epoch),
		runs : List(Closure.RunWire),
		nearest : List(Closure.NearestWire),
		hints : List(Closure.Hint),
		log_size : U64,
		unknown : List(Str),
		checked : List(Closure.CheckedWire),
		repos : List(Closure.RepoWire),
	}

	bad : Str, Str -> [BadJson(Str)]
	bad = |what, text| BadJson("unknown ${what} ${text}")

	source_text : Code.Source -> Str
	source_text = |s| match s {
		Bot => "bot"
		Author => "author"
	}

	source_of : Str -> Try(Code.Source, [BadJson(Str)])
	source_of = |text| match text {
		"bot" => Ok(Bot)
		"author" => Ok(Author)
		_ => Err(bad("source", text))
	}

	result_of : Str -> Try(Code.Result, [BadJson(Str)])
	result_of = |text| Code.result_from_str(text).map_err(|_| bad("result", text))

	## The wire form of one `checked` item and of one `repos` item (also used by `Index`).
	checked_to_wire : Closure.Checked -> Closure.CheckedWire
	checked_to_wire = |c| { name: c.name, checked_at: Nullable.write(c.checked_at), stale: c.stale }

	checked_from_wire : Closure.CheckedWire -> Closure.Checked
	checked_from_wire = |c| { name: c.name, checked_at: Nullable.read(c.checked_at), stale: c.stale }

	repo_to_wire : Closure.Repo -> Closure.RepoWire
	repo_to_wire = |r| {
		name: r.name,
		state: match r.state {
			Active => "active"
			Missing => "missing"
			Moved => "moved"
		},
		successor: Nullable.write(r.successor),
		state_at: r.state_at,
	}

	repo_from_wire : Closure.RepoWire -> Try(Closure.Repo, [BadJson(Str)])
	repo_from_wire = |r| {
		state = match r.state {
			"active" => Ok(Active)
			"missing" => Ok(Missing)
			"moved" => Ok(Moved)
			other => Err(bad("state", other))
		}?
		Ok({ name: r.name, state, successor: Nullable.read(r.successor), state_at: r.state_at })
	}

	## Slice 104b. One item of `checked` (R-AP29) or `repos` (R-AP32) as a JSON object, for the read routes (R-AP1, R-AP2, R-AP13, R-AP14). Members in the order of the derived codec (alphabetical), so 2 answers of one state have the same bytes (R-AP24). `checked_at` and `successor` are written as `null` for none (R-AP51). The decoders follow R-AP51: a missing required member, a null `name`, or an unknown `state` is `BadJson`.
	encode_checked : Closure.Checked -> Str
	encode_checked = |c| Json.to_str({ name: c.name, checked_at: Nullable.write(c.checked_at), stale: c.stale })

	decode_checked : Str -> Try(Closure.Checked, [BadJson(Str)])
	decode_checked = |text| {
		parsed : Try(Closure.CheckedWire, _)
		parsed = Json.parse(text)
		parsed.map_ok(|c| { name: c.name, checked_at: Nullable.read(c.checked_at), stale: c.stale }).map_err(|e| BadJson(Str.inspect(e)))
	}

	encode_repo : Closure.Repo -> Str
	encode_repo = |r| Json.to_str({
		name: r.name,
		state: match r.state {
			Active => "active"
			Missing => "missing"
			Moved => "moved"
		},
		successor: Nullable.write(r.successor),
		state_at: r.state_at,
	})

	decode_repo : Str -> Try(Closure.Repo, [BadJson(Str)])
	decode_repo = |text| {
		parsed : Try(Closure.RepoWire, _)
		parsed = Json.parse(text)
		match parsed {
			Err(e) => Err(BadJson(Str.inspect(e)))
			Ok(r) => {
				state = match r.state {
					"active" => Ok(Active)
					"missing" => Ok(Missing)
					"moved" => Ok(Moved)
					other => Err(bad("state", other))
				}?
				Ok({ name: r.name, state, successor: Nullable.read(r.successor), state_at: r.state_at })
			}
		}
	}

	decode_request : Str -> Try(Closure.Request, [BadJson(Str)])
	decode_request = |text| {
		parsed : Try(Closure.RequestWire, _)
		parsed = Json.parse(text)
		parsed.map_ok(
			|w| {
				groups: w.groups.map(|g| { group: g.group, series: Nullable.read_opt(g.series), range: Nullable.read_opt(g.range) }),
				hashes: w.hashes,
				compilers: Nullable.read_opt(w.compilers).map_ok(|c| { from: Nullable.read_opt(c.from), to: Nullable.read_opt(c.to) }),
			},
		).map_err(|e| BadJson(Str.inspect(e)))
	}

	encode_request : Closure.Request -> Str
	encode_request = |req| Json.to_str({
		groups: req.groups.map(|g| { group: g.group, series: Nullable.write_opt(g.series), range: Nullable.write_opt(g.range) }),
		hashes: req.hashes,
		compilers: Nullable.write_opt(req.compilers.map_ok(|c| { from: Nullable.write_opt(c.from), to: Nullable.write_opt(c.to) })),
	})

	decode_answer : Str -> Try(Closure.Answer, [BadJson(Str)])
	decode_answer = |text| {
		parsed : Try(Closure.AnswerWire, _)
		parsed = Json.parse(text)
		match parsed {
			Err(e) => Err(BadJson(Str.inspect(e)))
			Ok(w) => {
				artifacts = w.artifacts.map_try(Artifact.from_wire)?
				runs = w.runs.map_try(|r| Ok({ hash: r.hash, target: r.target, source: source_of(r.source)?, result: result_of(r.result)?, error_digest: Nullable.read(r.error_digest), from: r.from, to: r.to }))?
				nearest = w.nearest.map_try(
					|n| Ok({
						hash: n.hash,
						target: n.target,
						source: source_of(n.source)?,
						result: result_of(n.result)?,
						error_digest: Nullable.read(n.error_digest),
						nightly: n.nightly,
						side: match n.side {
							"before" => Before
							"after" => After
							other => return Err(bad("side", other))
						},
					}),
				)?
				repos = w.repos.map_try(
					|r| Ok({
						name: r.name,
						state: match r.state {
							"active" => Active
							"missing" => Missing
							"moved" => Moved
							other => return Err(bad("state", other))
						},
						successor: Nullable.read(r.successor),
						state_at: r.state_at,
					}),
				)?
				Ok({
					artifacts,
					releases: w.releases.map(Release.from_wire),
					epochs: w.epochs,
					runs,
					nearest,
					hints: w.hints,
					log_size: w.log_size,
					unknown: w.unknown,
					checked: w.checked.map(|c| { name: c.name, checked_at: Nullable.read(c.checked_at), stale: c.stale }),
					repos,
				})
			}
		}
	}

	encode_answer : Closure.Answer -> Str
	encode_answer = |ans| Json.to_str({
		artifacts: ans.artifacts.map(Artifact.to_wire),
		releases: ans.releases.map(Release.to_wire),
		epochs: ans.epochs,
		runs: ans.runs.map(|r| { hash: r.hash, target: r.target, source: source_text(r.source), result: Code.result_to_str(r.result), error_digest: Nullable.write(r.error_digest), from: r.from, to: r.to }),
		nearest: ans.nearest.map(
			|n| {
				hash: n.hash,
				target: n.target,
				source: source_text(n.source),
				result: Code.result_to_str(n.result),
				error_digest: Nullable.write(n.error_digest),
				nightly: n.nightly,
				side: match n.side {
					Before => "before"
					After => "after"
				},
			},
		),
		hints: ans.hints,
		log_size: ans.log_size,
		unknown: ans.unknown,
		checked: ans.checked.map(|c| { name: c.name, checked_at: Nullable.write(c.checked_at), stale: c.stale }),
		repos: ans.repos.map(
			|r| {
				name: r.name,
				state: match r.state {
					Active => "active"
					Missing => "missing"
					Moved => "moved"
				},
				successor: Nullable.write(r.successor),
				state_at: r.state_at,
			},
		),
	})
}
