## The pure part of `POST /v1/compat`, the user hint path (Registry 4.1: R-AP10, R-AP25, R-AP41, R-AP46, R-AP48, R-AP51; 6: R-MX5, R-MX6; 6.1: R-CT1 to R-CT4, R-CT12 to R-CT14; R-RE12, R-RE13 row 3, R-RE16, R-RE24; slice 116a).
## No effect, no platform import. The effects (the body read, the D1 calls, the tag list of GitHub, the clock) are in `worker/HintRoutes.roc`.
## The tests are `worker/tests/unit/HintsTest.roc` (W0) and `worker/tests/cases/hints/` (W2). The slice file is `docs/slices/116a-user-hints.md`.
## The `detail` texts, the order of the members of the answer, and the SQL texts are proposals for the human review (TW24): the slice file section 6.
## The doc comment of each function is the rule. The bot path is `worker/lib/Compat.roc`: this module reuses its types `Compat.Reject`, `Compat.Facts`, `Compat.Constraint`, `Compat.written_status`.
import records.Code
import records.Id
import records.Compat as Wire
import semver.Semver
import Compat
import Problem
import Reads

Hints :: [].{

	## R-CT3, R-RE16: the contributor of a machine (the first 8 bytes of HMAC-SHA256 with the top bit set) is an `I64` below 0 (`hmac_message`, `contributor_id`).
	## R-CT12: the version of `tln` that is not a release of Talon is stored as the key 0 (`unknown`, R-IK5).
	unknown_version : I64
	unknown_version = 0

	## R-CT12: the tag list of `roc-talon/talon` (R-CT12, Design Q178): one page, a known limit, 100 tags. The Worker reads it at most once an hour.
	tags_url : Str
	tags_url = "https://api.github.com/repos/roc-talon/talon/tags?per_page=100"

	## A row of the body (R-AP10, R-CT2) after the checks of `parse`. `hash` is the text as sent, `artifact` its id, `nightly` the id of the tag, `target` the name as sent,
	## `result` one of `Pass`, `Fail`, `Crash` (a `Hang` is not a hint).
	Row : { hash : Str, artifact : I64, nightly : I64, target : Str, result : Code.Result }

	## A body that passed `parse`: `talon_version` as sent (any text, R-CT12), the rows in the order of the body.
	Post : { talon_version : Str, rows : List(Hints.Row) }

	## R-CT1: the id of the header `Talon-Contributor`: 32 characters, each one of `0` to `9` and `a` to `f`. `Ok(id)` is the same text. Else `Err(problem)`, 400 `bad-request`;
	## the `detail` names the header `Talon-Contributor`. A capital letter, 31 or 33 characters, a space or an empty text are refused.
	machine_id : Str -> Try(Str, Problem)
	machine_id = |id| {
		bytes = id.to_utf8()
		if bytes.len() == 32 and bytes.all(is_hex_lower) {
			Ok(id)
		} else {
			Err(Problem.new(BadRequest, "the header Talon-Contributor must be 32 characters, each one of 0 to 9 and a to f"))
		}
	}

	is_hex_lower : U8 -> Bool
	is_hex_lower = |b| (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f')

	## The checks 4 to 6 of R-AP48 and R-AP66 for a hint body, in this order. The first that fails gives the answer, and the route makes no D1 call. The route has the 413 of a body above
	## `Compat.body_limit` bytes before the id check (`Compat.too_large("body", ...)`), so this function is called with a body of any size and gives the same 413 first.
	## 1. More than `Compat.body_limit` bytes: 413, field `body`.
	## 2. The body is not valid (400 `bad-request`, the `detail` names the member for a missing one, R-AP51): not UTF-8, not JSON, not an object, `rows` missing or `null`, a row that is not an
	##    object, a row without `hash`, `nightly`, `target` or `result`, `talon_version` missing, `null` or not a text, a wrong JSON type. A member that is not known is ignored (R-AP44) with these
	##    exceptions, each one 400 (R-AP70 row 6, Design Q176): `error_digest` in a row, with any value, also `null` (R-CT2: no table keeps it); `source` in the body or in a row, with any value, also `null`
	##    and also written with a JSON escape (R-MX5, G17); `sweep` in the body, with any value (R-AP10: bot only). A text that holds the word as a value is not a member.
	## 3. More than `Compat.row_limit` rows: 413, field `rows`, limit 500 (R-CT2, R-AP46).
	## 4. The values of all rows, in the order of the rows; in a row `hash`, then `nightly`, then `result`: a `hash` that is not base58 of exactly 32 bytes, a `nightly` with no nightly id (R-IK4),
	##    a `result` that is not `pass`, `fail` or `crash` (`hang` too: "A hang is not a hint", R-CT2). `talon_version` is any text and never gives a 400 (R-CT12).
	## `rows: []` is valid. `target` is any text here: a name with no code is a skip, not a 400.
	parse : List(U8) -> Try(Hints.Post, Compat.Reject)
	parse = |body| {
		if body.len() > Compat.body_limit {
			return Err(Compat.too_large("body", Compat.body_limit))
		}
		text = Str.from_utf8(body).map_err(|_| bad("the hint request body is not valid: it is not UTF-8"))?
		wire = match Wire.decode_hint_post(text) {
			Ok(found) => found
			Err(BadJson(detail)) => return Err(bad("the hint request body is not valid: ${detail}"))
		}
		if wire.rows.len() > Compat.row_limit {
			return Err(Compat.too_large("rows", Compat.row_limit))
		}
		rows = wire.rows.map_try(row_of)?
		Ok({ talon_version: wire.talon_version, rows })
	}

	bad : Str -> Compat.Reject
	bad = |detail| Bad(Problem.new(BadRequest, detail))

	## The values of one row: `hash`, then `nightly`, then `result`.
	row_of : Wire.HintRow -> Try(Hints.Row, Compat.Reject)
	row_of = |r| {
		artifact = Reads.artifact_id(r.hash).map_err(|_| bad("the hash ${r.hash} of a row is not a base58 hash of 32 bytes"))?
		nightly = Id.nightly_id(r.nightly).map_err(|_| bad("the nightly ${r.nightly} of a row is not a nightly tag"))?
		result = match Code.result_from_str(r.result) {
			Ok(Hang) => return Err(bad("the result hang of a row is not a hint"))
			Ok(found) => found
			Err(_) => return Err(bad("the result ${r.result} of a row is not pass, fail or crash"))
		}
		Ok({ hash: r.hash, artifact, nightly, target: r.target, result })
	}

	## R-AP41 row 2: the two lists of the read batch (D1 call 1), as for the bot path: `artifacts_json` the distinct ids of the rows in the order of the first row, as JSON integers;
	## `targets_json` the distinct `target` names other than `any`, as JSON strings, in the same order. The route sends the 3 statements of `CompatRoutes.plan!` (`artifacts`, `targets`, `artifact_targets`; copy the text: `HintRoutes` cannot import `CompatRoutes`).
	read_params : Hints.Post -> { artifacts_json : Str, targets_json : Str }
	read_params = |post| {
		ids = post.rows.fold([], |acc, r| if (acc.contains(r.artifact)) acc else acc.append(r.artifact))
		names = post.rows.fold([], |acc, r| if (r.target == "any" or acc.contains(r.target)) acc else acc.append(r.target))
		{
			artifacts_json: "[${Str.join_with(ids.map(I64.to_str), ",")}]",
			targets_json: "[${Str.join_with(names.map(|n| Json.to_str(n)), ",")}]",
		}
	}

	## A row for the write batch (D1 call 2): `index` is the place of the row in the body (the `row` of `skipped`), `target` is the code (R-IK7), or `Err(NoCode)` for a name with no code
	## (SQL then skips the row as `unknown-target`), `result` the code 0, 1 or 3.
	Sent : { index : U64, artifact : I64, nightly : I64, target : Try(I64, [NoCode]), result : U8 }

	## R-CT2 against the read batch: the 400 of a row. The rows are checked in order and the first that fails gives the problem. A row never gives a 404 here: a hash with no `artifacts`
	## fact is not a 400 (the batch skips it as `unknown-hash`), also with a real target.
	## 1. The `target` is `any`: code 0, for each kind of artifact.
	## 2. A real target and the artifact has a fact: the kind must be app (0) or platform (2), else 400 `bad-request` ("a real target only when the artifact kind is app or platform").
	##    A package with any real target name is a 400, also a name with no code.
	## 3. A platform: the name, if it has a code, must be in `platform_targets` of the artifact (as R-MX10), else 400 (R-CT2, Design Q173). An app: any name with a code.
	## 4. A name with no code in `target_rows`: `Err(NoCode)` (a skip, R-CT14), no 400.
	## The `detail` of a 400 names the target and the artifact hash. The result lists all rows in the order of the body.
	check : Hints.Post, Compat.Facts -> Try(List(Hints.Sent), Problem)
	check = |post, facts| post.rows.map_with_index(|r, i| (r, i)).map_try(|(r, i)| sent_of(r, i, facts))

	sent_of : Hints.Row, U64, Compat.Facts -> Try(Hints.Sent, Problem)
	sent_of = |r, index, facts| {
		target = target_of(r, facts)?
		Ok({ index, artifact: r.artifact, nightly: r.nightly, target, result: Code.result_code(r.result) })
	}

	## The code of the target of a row, or the 400 of the target rule (R-CT2, Design Q173).
	target_of : Hints.Row, Compat.Facts -> Try(Try(I64, [NoCode]), Problem)
	target_of = |r, facts| {
		if r.target == "any" {
			return Ok(Ok(0))
		}
		code = match facts.target_rows.find_first(|t| t.name == r.target) {
			Ok(t) => Ok(t.target)
			Err(_) => Err(NoCode)
		}
		match facts.artifacts.find_first(|a| a.artifact == r.artifact) {
			Err(_) => Ok(code)
			Ok(a) => match a.kind {
				0 => Ok(code)
				2 => match code {
					Ok(c) => if (facts.platform_targets.any(|p| p.artifact == r.artifact and p.target == c)) Ok(code) else Err(Problem.new(BadRequest, "the platform ${r.hash} does not build the target ${r.target}"))
					Err(NoCode) => Ok(code)
				}
				_ => Err(Problem.new(BadRequest, "the target ${r.target} is not valid for a hint: the artifact ${r.hash} is a package"))
			}
		}
	}

	## The parameter ?1 of the three write statements: the JSON text of the rows for `json_each`. The members: `i` (the index), `artifact`, `nightly` (JSON integers, R-IK2), `target`
	## (a JSON integer, or `null` for `Err(NoCode)`), `result` (0, 1, 3). The members are the contract between this function and the SQL texts.
	rows_json : List(Hints.Sent) -> Str
	rows_json = |rows| {
		items = rows.map(
			|r| {
				target = match r.target {
					Ok(code) => code.to_str()
					Err(NoCode) => "null"
				}
				"{\"i\":${r.index.to_str()},\"artifact\":${r.artifact.to_str()},\"nightly\":${r.nightly.to_str()},\"target\":${target},\"result\":${r.result.to_str()}}"
			},
		)
		"[${Str.join_with(items, ",")}]"
	}

	## Statement 1 of R-CT4 (`first`). Parameters: ?1 `rows_json`, ?2 the time in ms. One row, one column `first`: the count of the distinct pairs (artifact, nightly, target) of the rows that
	## `skipped_sql` does not skip, that have no `compat` row of any source and no `compat_hints` row of any `talon_version`. It runs before the insert in the same batch, so it sees the state before.
	first_sql : () -> Str
	first_sql = || "${classified}SELECT COUNT(*) AS first FROM (SELECT DISTINCT p.artifact, p.nightly, p.target FROM c p WHERE p.reason IS NULL AND NOT EXISTS (SELECT 1 FROM compat x WHERE x.artifact = p.artifact AND x.nightly = p.nightly AND x.target = p.target) AND NOT EXISTS (SELECT 1 FROM compat_hints h WHERE h.artifact = p.artifact AND h.nightly = p.nightly AND h.target = p.target))"

	## The text that the three statements share: the rows of `json_each(?1)` (`r`), and each row with the first reason that skips it, or NULL (`c`). The order of the reasons is R-CT14.
	## 31536000000 ms are 365 days (Design Q174): the smallest `published_at` of the nightly decides, and a nightly at exactly the edge is not old.
	classified : Str
	classified = "WITH r AS (SELECT CAST(json_extract(j.value, '$.i') AS INTEGER) AS i, json_extract(j.value, '$.artifact') AS artifact, json_extract(j.value, '$.nightly') AS nightly, json_extract(j.value, '$.target') AS target, json_extract(j.value, '$.result') AS result FROM json_each(?1) j), c AS (SELECT r.i AS i, r.artifact AS artifact, r.nightly AS nightly, r.target AS target, r.result AS result, CASE WHEN NOT EXISTS (SELECT 1 FROM artifacts a WHERE a.artifact = r.artifact) THEN 'unknown-hash' WHEN NOT EXISTS (SELECT 1 FROM toolchains t WHERE t.nightly = r.nightly) THEN 'unknown-nightly' WHEN r.target IS NULL THEN 'unknown-target' WHEN EXISTS (SELECT 1 FROM compat b WHERE b.artifact = r.artifact AND b.nightly = r.nightly AND b.target = r.target AND b.source = 0) THEN 'bot-row' WHEN (SELECT MIN(t.published_at) FROM toolchains t WHERE t.nightly = r.nightly) < ?2 - 31536000000 THEN 'old-nightly' END AS reason FROM r) "

	## Statement 2 of R-CT4 (`skipped`), R-CT14. Parameters: ?1 `rows_json`, ?2 the time in ms. The rows that are skipped, columns `row` (the index, `i`) and `reason`, ordered by `row`.
	## The reason is the first of this list that holds (the order of the table in R-CT14, Design Q174 for the age):
	## `unknown-hash` (no `artifacts` row), `unknown-nightly` (no `toolchains` row of the nightly), `unknown-target` (`target` is null), `bot-row` (a `compat` row with source 0 on the pair),
	## `old-nightly` (the smallest `published_at` of the nightly in `toolchains` is below ?2 minus 365 days, 31,536,000,000 ms).
	skipped_sql : () -> Str
	skipped_sql = || "${classified}SELECT i AS row, reason FROM c WHERE reason IS NOT NULL ORDER BY i"

	## Statement 3 of R-CT4 (`written`). Parameters: ?1 `rows_json`, ?2 the time in ms, ?3 the id of the machine (from `contributor_id`, as a decimal text: R-IK2), ?4 `talon_version` (the key from
	## `talon_key`). It inserts the rows that `skipped_sql` does not skip into `contributions` (R-RE16) with `contributor` = `COALESCE((SELECT contributor FROM links WHERE machine = ?3), ?3)` (R-CT3),
	## `time` ?2, ending in `ON CONFLICT (contributor, artifact, nightly, target) DO NOTHING RETURNING CAST(artifact AS TEXT)`. Never `INSERT OR IGNORE` (R-CT4: it drops a row that fails a `CHECK`).
	## The route counts the returned rows (not `changes`: on D1 `changes` counts the rows of the trigger).
	insert_sql : () -> Str
	insert_sql = || "${classified}INSERT INTO contributions (contributor, artifact, nightly, target, result, talon_version, time) SELECT COALESCE((SELECT contributor FROM links WHERE machine = CAST(?3 AS INTEGER)), CAST(?3 AS INTEGER)), artifact, nightly, target, result, CAST(?4 AS INTEGER), ?2 FROM c WHERE reason IS NULL ORDER BY i ON CONFLICT (contributor, artifact, nightly, target) DO NOTHING RETURNING CAST(artifact AS TEXT) AS artifact"

	## R-CT3: the bytes that the Worker authenticates with `WebCrypto.hmac_sha256(CONTRIBUTOR_KEY, ...)`: the 32 characters of the id of the header as UTF-8 bytes (R-CT3, Design Q175: the other option is the 16 bytes
	## that the hex text stands for). `lib` has no platform import, so the HMAC call is in `HintRoutes`.
	hmac_message : Str -> List(U8)
	hmac_message = |machine| machine.to_utf8()

	## R-CT3: the contributor id of a machine from the HMAC-SHA256 output (32 bytes): the first 8 bytes read as a big-endian unsigned number, `bitwise_or` with 2^63, read as an `I64`: always below 0.
	## A list shorter than 8 bytes reads the missing bytes as 0.
	contributor_id : List(U8) -> I64
	contributor_id = |mac| {
		bytes = mac.take_first(8).concat(List.repeat(0, 8 - mac.take_first(8).len()))
		number = bytes.fold(0.U64, |acc, b| acc.shl_wrap(8).bitwise_or(b.to_u64()))
		number.bitwise_or(9_223_372_036_854_775_808).to_i64_wrap()
	}

	## R-CT12: the value of `talon_version` that is stored. `version` is the text of the body, `tags` the names of the tags of `roc-talon/talon`. When `v<version>` is in `tags` and `version` is
	## a semver (`Semver.parse`), the key of `Semver.to_key` read as an `I64` with `to_i64_wrap`, with no flip (R-IK5, Design Q177); else `unknown_version` (0). A pre-release has its own key.
	## The match of the tag is exact text: `v0.4.1` in `tags` and `version` `0.4.1`. `v0.4.1` as the version, `0.4.01`, an empty text or a build from source are 0.
	talon_key : { version : Str, tags : List(Str) } -> I64
	talon_key = |x| {
		if x.tags.contains("v${x.version}") {
			match Semver.parse(x.version) {
				Ok(semver) => semver.to_key().key.to_i64_wrap()
				Err(_) => unknown_version
			}
		} else {
			unknown_version
		}
	}

	## R-CT12: the names of the tags in the JSON text that `GET /repos/{owner}/{repo}/tags` gives: an array of objects with the member `name`. Other members are ignored. Not an array, or an item
	## with no text `name`: `Err(BadTags)`. An empty array is `Ok([])`.
	tag_names : Str -> Try(List(Str), [BadTags])
	tag_names = |text| {
		parsed : Try(List({ name : Str }), _)
		parsed = Json.parse(text)
		match parsed {
			Ok(tags) => Ok(tags.map(|t| t.name))
			Err(_) => Err(BadTags)
		}
	}

	## R-CT14: a skipped row, as the answer lists it: `row` is the index in the request, `reason` the text of the SQL (`skipped_sql`).
	Skipped : Wire.HintSkip

	## The body of the 2xx answer (R-AP10, `Compat.encode_hint_answer` of `records`, slice 124): `{"written":<n>,"first":<k>,"skipped":[{"row":<i>,"reason":"<reason>"},...]}`. The members in this order, `skipped` always (an empty list is `[]`),
	## the items in the order given. The status is `Compat.written_status(written)`.
	answer_body : { written : U64, first : U64, skipped : List(Hints.Skipped) } -> Str
	answer_body = |x| Wire.encode_hint_answer({ written: x.written, first: x.first, skipped: x.skipped })

	## R-CT13 (R-MX9 for hints): what a failed write batch is. `Constraint` of kind `Trigger` with the whole `message` `hint-quota`: `Quota`. Everything else (another text, a `Check` failure, another kind
	## with the text `hint-quota`, a text that only has `hint-quota`): `Fault(text)`, 500 `internal`. A hint request never gets `sweep-incomplete` (R-MX9).
	failure_of : Compat.Constraint -> [Quota, Fault(Str)]
	failure_of = |c| match (c.kind, c.message) {
		(Trigger, "hint-quota") => Quota
		_ => Fault(c.message)
	}

	## R-CT13, R-AP25: the `Retry-After` value in seconds for `now_ms`: the time to the start of the next UTC day, rounded up to a whole second (R-CT13, Design Q179). At 00:00:00.000 it is 86400.
	retry_after : U64 -> U64
	retry_after = |now_ms| {
		day_ms = 86_400_000
		left_ms = day_ms - now_ms % day_ms
		(left_ms + 999) // 1000
	}

	## R-CT13: the problem of the 429. Kind `RateLimited`. `detail` (proposal): `the daily limit of user hints is used up: send the rows again after the next UTC day starts`.
	quota_problem : () -> Problem
	quota_problem = || Problem.new(RateLimited, "the daily limit of user hints is used up: send the rows again after the next UTC day starts")
}
