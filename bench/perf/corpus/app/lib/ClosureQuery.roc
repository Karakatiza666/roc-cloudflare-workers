## The pure part of `POST /v1/closure` (Registry 4.1: R-AP3, R-AP16, R-AP17, R-AP18, R-AP28, R-AP41 rows 2 and 4, R-AP46, R-AP48, R-AP51; slice 110).
## No effect, no platform import. The effects (the body read, the one D1 batch, the clock) are in `worker/ClosureRoute.roc`.
## The SQL is in `worker/sql/closure/*.sql` (the code agent writes it). The W1 cases `sql/tests/cases/closure/` run the same files.
## The tests are `worker/tests/unit/ClosureQueryTest.roc` (W0) and `worker/tests/cases/closure/` (W2). The slice file is `docs/slices/110-closure.md`.
## The `detail` texts are proposals for the human review (TW24): the slice file section 6.
import records.Closure
import records.Code
import records.Id
import records.Release
import semver.Semver
import semver.VersionReq
import Problem
import Reads
import Version

ClosureQuery :: [].{

	## R-AP46: the request body, in bytes (256 KB).
	body_limit : U64
	body_limit = 262_144

	## R-AP46: the items of `groups`.
	group_limit : U64
	group_limit = 300

	## R-AP46: the items of `hashes`.
	hash_limit : U64
	hash_limit = 1_000

	## R-AP3: the `Cache-Control` of the answer.
	cache_control : Str
	cache_control = "no-store"

	## One group of the request, for the filter step after the batch (R-AP41 row 4, R-AP16). `range` is the text as sent (it parses: `parse` checked it).
	Filter : { group : Str, series : Try(Str, [None]), range : Try(Str, [None]) }

	## The parsed request: the 4 parameters of the batch, and what the answer needs from the request.
	## `groups_json` (?1): `[{"form":<id>,"lo":<v>,"hi":<v>},...]`, one item for each group in the order of the request, no white space. `form` is `Reads.form_id(group)`.
	##   `lo` and `hi` are the stored version bounds (`Version.to_stored`, as JSON integers): `Version.series_bounds(series)` for a `series`, `Version.range_bounds` of
	##   the `range`, both: the larger `lo` and the smaller `hi` (as I64), neither: `I64.lowest` and `I64.highest`.
	## `hashes_json` (?2): `[<id>,...]`: `Reads.artifact_id` of each text of `hashes` that is a hash, in the order of the request, also a repeated one.
	## `from` (?3) and `to` (?4): `Id.nightly_id` of the tags of `compilers`, `Err(None)` (bound as NULL) for a missing end, a tag with no nightly id, or no `compilers` (R-AP60).
	## `hash_texts`: each text of `hashes` as sent, in order. `filters`: one for each group, in order.
	Query : {
		groups_json : Str,
		hashes_json : Str,
		from : Try(I64, [None]),
		to : Try(I64, [None]),
		hash_texts : List(Str),
		filters : List(ClosureQuery.Filter),
	}

	## A refused request. `Bad(problem)`: a 400, the answer is `problem.to_json()`. `TooLarge(problem, extra)`: a 413 `too-large`, the answer is
	## `Problem.to_json_with(problem, extra)` with the members `field` and `limit` (R-AP21, R-AP46), as `Shorts` does. Both are `application/problem+json`.
	Reject : [Bad(Problem), TooLarge(Problem, { field : Str, limit : U64 })]

	## R-AP46: the 413 of a field and its limit, for example `too_large("groups", 300)`. The `detail` text is the proposal of the slice file section 6.
	## The route also gives it for a body that `Request.bytes_with!` refuses (`field` `body`).
	too_large : Str, U64 -> ClosureQuery.Reject
	too_large = |field, limit| TooLarge(Problem.new(TooLarge, "the ${field} of the closure request is larger than its limit of ${limit.to_str()}"), { field, limit })

	## The checks of R-AP48 rows 4 and 6, in this order. The first that fails gives the problem, and the route makes no D1 call:
	## 1. More than `body_limit` bytes: 413 `too-large`, field `body`, limit `body_limit`.
	## 2. `Closure.decode_request` fails (not JSON, a missing `groups` or `hashes`, a wrong type, R-AP51): 400 `bad-request`.
	## 3. More than `group_limit` groups: 413, field `groups`, limit 300. Then more than `hash_limit` hashes: 413, field `hashes`, limit 1000.
	## 4. A `series` that `Version.series_bounds` refuses, or a `range` that `VersionReq.parse` refuses: 400 (R-AP62).
	## A tag of `compilers` that `Id.nightly_id` refuses is a missing end, `Err(None)`, not an error (R-AP60). A member of `compilers` that is not text is 400 (step 2).
	## A text of `hashes` that is not base58 of exactly 32 bytes is not an error: it goes to `unknown` (R-AP59).
	## A 413 is `TooLarge` (with `field` and `limit`), a 400 is `Bad`.
	parse : List(U8) -> Try(ClosureQuery.Query, ClosureQuery.Reject)
	parse = |body| {
		if body.len() > body_limit {
			return Err(too_large("body", body_limit))
		}
		req = decode(body)?
		if req.groups.len() > group_limit {
			return Err(too_large("groups", group_limit))
		}
		if req.hashes.len() > hash_limit {
			return Err(too_large("hashes", hash_limit))
		}
		items = req.groups.map_try(group_item)?
		ids = req.hashes.keep_oks(Reads.artifact_id)
		window = req.compilers ?? { from: Err(None), to: Err(None) }
		Ok({
			groups_json: "[${Str.join_with(items, ",")}]",
			hashes_json: "[${Str.join_with(ids.map(I64.to_str), ",")}]",
			from: nightly_of(window.from),
			to: nightly_of(window.to),
			hash_texts: req.hashes,
			filters: req.groups,
		})
	}

	## R-AP16, R-AP41 row 4, R-AP63: a release whose `group` is the `group` of a filter of the query stays only when it fits each such filter: its `series` is the `series`
	## of the filter (when the filter has one), and `VersionReq.matches` of the `range` (when it has one). A release of a group that no filter names stays.
	## A release whose `hash` is a text of `hash_texts` always stays (a header value stays in its domain, Resolution R-C9).
	keep_release : ClosureQuery.Query, Release.Row -> Bool
	keep_release = |query, release|
		query.hash_texts.contains(release.hash) or query.filters.keep_if(|f| f.group == release.group).all(|f| fits(f, release))

	## R-AP17 `unknown`: the texts of `hash_texts` that are not a hash, and the texts whose position in `hashes_json` is in `idx` (the `idx` column of
	## the statement `unknown`, a 0-based index into `hashes_json`), in the order of `hash_texts`, each text once.
	unknown_of : ClosureQuery.Query, List(U64) -> List(Str)
	unknown_of = |query, idx| {
		var $out = []
		var $pos = 0
		for text in query.hash_texts {
			missing = match Reads.artifact_id(text) {
				Ok(_) => {
					hit = idx.contains($pos)
					$pos = $pos + 1
					hit
				}
				Err(BadHash) => Bool.True
			}
			if missing and !$out.contains(text) {
				$out = $out.append(text)
			}
		}
		$out
	}

	## A row of the statement `deps`: `Reads.DepRow` with `owner`, the hash (`names.value`) of the artifact that has the dep.
	DepRow : { owner : List(U8), alias : Str, hash : List(U8), form : Try(Str, [Missing]), version : Try(Str, [Missing]), version_text : Try(Str, [Missing]), url : Str, is_platform : Bool }

	## A row of the statement `targets`: the target names of a platform.
	TargetRow : { owner : List(U8), name : Str }

	## A row of `unknown`.
	UnknownRow : { idx : U64 }

	## A row of `runs`. `source`: 0 bot, 1 author. `result`: 0 pass, 1 fail, 2 hang, 3 crash (R-IK7). `from` and `to` are tags.
	RunRow : { hash : List(U8), target : Str, source : I64, result : I64, error_digest : Try(Str, [Missing]), from : Str, to : Str }

	## A row of `nearest`. `side` is `before` or `after`.
	NearestRow : { hash : List(U8), target : Str, source : I64, result : I64, error_digest : Try(Str, [Missing]), nightly : Str, side : Str }

	## A row of `hints`.
	HintRow : { hash : List(U8), nightly : Str, target : Str, pass_count : U64, fail_count : U64, crash_count : U64 }

	## The rows of the 12 statements of the one batch (the slice file section 4), in the order of the SQL. `target_rows` holds the rows of the statement `targets` (`targets` is a keyword of Roc).
	Rows : {
		artifacts : List(Reads.ArtifactRow),
		deps : List(ClosureQuery.DepRow),
		target_rows : List(ClosureQuery.TargetRow),
		releases : List(Reads.ReleaseRow),
		unknown : List(ClosureQuery.UnknownRow),
		epochs : List(Closure.Epoch),
		runs : List(ClosureQuery.RunRow),
		nearest : List(ClosureQuery.NearestRow),
		hints : List(ClosureQuery.HintRow),
		checked : List(Reads.CheckRow),
		repos : List(Reads.RepoRow),
		log_size : U64,
	}

	## The body of the 200 answer (R-AP17, R-AP32): `Closure.encode_answer` of the answer that the rows give.
	## `artifacts`: `Reads.artifact_of_rows` of each artifact row with its deps and targets (the rows whose `owner` is its hash), in the order of the rows.
	## `releases`: `Reads.release_of_row` of each row, then `keep_release(query, release)` (R-AP63). `epochs`: as read.
	## `runs`, `nearest`: the hash in base58, the codes as `Code.Source` and `Code.Result`, `error_digest` `null` for NULL (R-AP58), `side` `Before` or `After`.
	## `hints`: the hash in base58. `unknown`: `unknown_of`. `checked`: `Reads.checked_of_row(row, now_ms)`. `repos`: `Reads.repo_item_of_row`.
	## A row that does not convert (a hash of other than 32 bytes, an unknown code, an `exposes` that is not a JSON array) is `Err(BadRow(text))`: 500 `internal`.
	answer : ClosureQuery.Query, ClosureQuery.Rows, U64 -> Try(Str, [BadRow(Str)])
	answer = |query, rows, now_ms| {
		artifacts = rows.artifacts.map_try(|a| artifact_of(rows, a))?
		all = rows.releases.map_try(Reads.release_of_row)?
		runs = rows.runs.map_try(run_of)?
		nearest = rows.nearest.map_try(nearest_of)?
		hints = rows.hints.map_try(hint_of)?
		repos = rows.repos.map_try(Reads.repo_item_of_row)?
		Ok(
			Closure.encode_answer({
				artifacts,
				releases: all.keep_if(|r| keep_release(query, r)),
				epochs: rows.epochs,
				runs,
				nearest,
				hints,
				log_size: rows.log_size,
				unknown: unknown_of(query, rows.unknown.map(|u| u.idx)),
				checked: rows.checked.map(|c| Reads.checked_of_row(c, now_ms)),
				repos,
			}),
		)
	}

	# ---- helpers (private use) ----

	## Step 2 of `parse`: the text and its decode (R-AP51).
	decode : List(U8) -> Try(Closure.Request, ClosureQuery.Reject)
	decode = |body| {
		text = Str.from_utf8(body).map_err(|_| bad("the closure request body is not valid: it is not UTF-8"))?
		Closure.decode_request(text).map_err(
			|e| match e {
				BadJson(why) => bad("the closure request body is not valid: ${why}")
			},
		)
	}

	bad : Str -> ClosureQuery.Reject
	bad = |detail| Bad(Problem.new(BadRequest, detail))

	## Step 4 of `parse`: one item of `groups_json`. The bounds of the series and of the range meet: the larger `lo`, the smaller `hi`.
	group_item : ClosureQuery.Filter -> Try(Str, ClosureQuery.Reject)
	group_item = |g| {
		all = { lo: I64.lowest, hi: I64.highest }
		series = match g.series {
			Ok(text) => match Version.series_bounds(text) {
				Ok(b) => stored(b)
				Err(BadSeries) => return Err(bad("the series ${text} of the group ${g.group} is not a series (M or 0.m)"))
			}
			Err(None) => all
		}
		range = match g.range {
			Ok(text) => match VersionReq.parse(text) {
				Ok(req) => stored(Version.range_bounds(req))
				Err(_) => return Err(bad("the range ${text} of the group ${g.group} is not a version range"))
			}
			Err(None) => all
		}
		lo = I64.max(series.lo, range.lo)
		hi = I64.min(series.hi, range.hi)
		Ok("{\"form\":${I64.to_str(Reads.form_id(g.group))},\"lo\":${I64.to_str(lo)},\"hi\":${I64.to_str(hi)}}")
	}

	## The bounds of `Version` are the decimal text of an `I64`, so the fallback is not used.
	stored : Version.Bounds -> { lo : I64, hi : I64 }
	stored = |b| { lo: I64.from_str(b.lo) ?? I64.lowest, hi: I64.from_str(b.hi) ?? I64.highest }

	## R-AP60: a tag with no nightly id is a missing end.
	nightly_of : Try(Str, [None]) -> Try(I64, [None])
	nightly_of = |tag| match tag {
		Ok(text) => Id.nightly_id(text).map_err(|_| None)
		Err(None) => Err(None)
	}

	## A release fits a filter: the series (when the filter has one), and `VersionReq.matches` of the range (when it has one).
	fits : ClosureQuery.Filter, Release.Row -> Bool
	fits = |f, release| {
		series_ok = match f.series {
			Ok(text) => release.series == text
			Err(None) => Bool.True
		}
		range_ok = match f.range {
			Ok(text) => match (VersionReq.parse(text), Semver.parse(release.version)) {
				(Ok(req), Ok(v)) => req.matches(v)
				_ => Bool.False
			}
			Err(None) => Bool.True
		}
		series_ok and range_ok
	}

	artifact_of : ClosureQuery.Rows, Reads.ArtifactRow -> Try(_, [BadRow(Str)])
	artifact_of = |rows, a| {
		deps = rows.deps.keep_if(|d| d.owner == a.hash).map(|d| { alias: d.alias, hash: d.hash, form: d.form, version: d.version, version_text: d.version_text, url: d.url, is_platform: d.is_platform })
		target_names = rows.target_rows.keep_if(|t| t.owner == a.hash).map(|t| t.name)
		Reads.artifact_of_rows({ artifact: a, deps, target_names })
	}

	source_of : I64 -> Try(Code.Source, [BadRow(Str)])
	source_of = |n| {
		code = n.to_u8_try().map_err(|_| BadRow("the source code ${n.to_str()} is not known"))?
		Code.source_from_code(code).map_err(|_| BadRow("the source code ${n.to_str()} is not known"))
	}

	result_of : I64 -> Try(Code.Result, [BadRow(Str)])
	result_of = |n| {
		code = n.to_u8_try().map_err(|_| BadRow("the result code ${n.to_str()} is not known"))?
		Code.result_from_code(code).map_err(|_| BadRow("the result code ${n.to_str()} is not known"))
	}

	run_of : ClosureQuery.RunRow -> Try(Closure.Run, [BadRow(Str)])
	run_of = |r| Ok({
		hash: Reads.base58_of_bytes(r.hash)?,
		target: r.target,
		source: source_of(r.source)?,
		result: result_of(r.result)?,
		error_digest: r.error_digest.map_err(|_| None),
		from: r.from,
		to: r.to,
	})

	nearest_of : ClosureQuery.NearestRow -> Try(Closure.Nearest, [BadRow(Str)])
	nearest_of = |r| {
		side = match r.side {
			"before" => Before
			"after" => After
			other => return Err(BadRow("the side ${other} is not known"))
		}
		Ok({
			hash: Reads.base58_of_bytes(r.hash)?,
			target: r.target,
			source: source_of(r.source)?,
			result: result_of(r.result)?,
			error_digest: r.error_digest.map_err(|_| None),
			nightly: r.nightly,
			side,
		})
	}

	hint_of : ClosureQuery.HintRow -> Try(Closure.Hint, [BadRow(Str)])
	hint_of = |h| Ok({ hash: Reads.base58_of_bytes(h.hash)?, nightly: h.nightly, target: h.target, pass_count: h.pass_count, fail_count: h.fail_count, crash_count: h.crash_count })
}
