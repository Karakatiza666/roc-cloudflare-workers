## The pure part of the toolchain routes (Registry 4: R-AP5, R-AP6, R-AP47, R-AP56, R-AP57; 7: R-PU7 to R-PU10; CLI 6.2: R-CV1 to R-CV3, R-CV8; slice 109). No effect, no platform import.
## 109b (Design Q340, R-AP80): the row has `size`, the byte size of the asset from the GitHub release, written once with the row. It is not in the leaf.
## The steps of `PUT` are R-AP57 (steps 1 to 7); the settled questions Q109-1 to Q109-9 are in `docs/slices/109-toolchains.md` section 7.1.
## The effects (the bot check, the D1 calls, the GitHub read, the clock) are in `worker/ToolchainRoutes.roc`.
## The tests are in `worker/tests/unit/ToolchainsTest.roc` (W0) and `worker/tests/cases/toolchains/` (W2).
## The texts of the `detail` of a problem and the member order of the bodies are proposals (TW24): `docs/slices/109-toolchains.md` section 5.
## Every body is built here as text, so that two answers of one state have the same bytes and the same ETag (R-AP24).
import records.Toolchain
import Problem

Toolchains :: [].{

	## R-AP5: at most this many rows in a page (first guess). The read asks for one more row, to know `more`.
	page_limit : U64
	page_limit = 1000

	## R-AP5: the `Cache-Control` of the 200 answer of `GET /v1/toolchains`.
	cache_control : Str
	cache_control = "max-age=300"

	## The six targets of CLI 6.2, R-CV8, in byte order of the text. The order of the rows of a new tag is this order (section 5 of the slice file).
	host_targets : List(Str)
	host_targets = ["linux_arm64", "linux_x86_64", "macos_apple_silicon", "macos_x86_64", "windows_arm64", "windows_x86_64"]

	## R-CV2: the end of the name of the asset of a target: `.zip` for the targets that start with `windows_`, else `.tar.gz`.
	archive_suffix : Str -> Str
	archive_suffix = |target| if (target.starts_with("windows_")) ".zip" else ".tar.gz"

	## R-PU8: the one GitHub call for a tag. The tag is a nightly tag (it has an id), so it has only letters, digits and `-`.
	release_url : Str -> Str
	release_url = |tag| "https://api.github.com/repos/roc-lang/nightlies/releases/tags/${tag}"

	# ---- the GitHub release (R-PU8) ----

	## An asset of the GitHub answer. `digest` is the text of the member `digest` (`sha256:<hex>` at GitHub today), or `Err(Missing)` for a missing member or `null`.
	## `size` (R-AP80) is the member `size`: `Ok(n)` for a whole number 0 or above, `Err(Missing)` for a missing member, `null`, a number with a fraction, or a negative number.
	## `parse_release` does not refuse the release for such a `size`: `select_assets` drops the asset. A `size` that is a text is not tested (slice file section 6).
	Asset : { name : Str, digest : Try(Str, [Missing]), size : Try(U64, [Missing]) }

	## The members of the GitHub release that the Worker reads. `published_at` is in ms (R-AP50, R-RE4). Other members are ignored (R-AP44).
	Release : { draft : Bool, prerelease : Bool, published_at : U64, assets : List(Toolchains.Asset) }

	## R-AP57 step 5: only `YYYY-MM-DDTHH:MM:SSZ` (the form of GitHub), to ms since 1970. A date that does not exist (`2026-02-30`), an hour above 23, a minute or
	## a second above 59, or another form (an offset such as `+00:00`, a fraction, a lower-case `z`) is `Err(BadTime)` (Q109-8).
	parse_time : Str -> Try(U64, [BadTime])
	parse_time = |text| match text.split_on("T") {
		[date, time] if time.ends_with("Z") => match (date.split_on("-"), time.drop_suffix("Z").split_on(":")) {
			([y, mo, d], [h, mi, s]) => {
				year = digits(y, 4)?
				month = digits(mo, 2)?
				day = digits(d, 2)?
				hour = digits(h, 2)?
				minute = digits(mi, 2)?
				second = digits(s, 2)?
				if month < 1 or month > 12 or day < 1 or day > days_in_month(year, month) or hour > 23 or minute > 59 or second > 59 {
					Err(BadTime)
				} else {
					days = days_from_civil(year.to_i64_wrap(), month.to_i64_wrap(), day.to_i64_wrap()).to_u64_try().map_err(|_| BadTime)?
					Ok((((days * 24 + hour) * 60 + minute) * 60 + second) * 1000)
				}
			}
			_ => Err(BadTime)
		}
		_ => Err(BadTime)
	}

	## Exactly `len` ASCII digits.
	digits : Str, U64 -> Try(U64, [BadTime])
	digits = |text, len| {
		if text.count_utf8_bytes() == len and text.to_utf8().all(|b| b >= 48 and b <= 57) {
			U64.from_str(text).map_err(|_| BadTime)
		} else {
			Err(BadTime)
		}
	}

	days_in_month : U64, U64 -> U64
	days_in_month = |y, m| {
		leap = (y % 4 == 0 and y % 100 != 0) or y % 400 == 0
		if m == 2 {
			if (leap) 29 else 28
		} else if m == 4 or m == 6 or m == 9 or m == 11 {
			30
		} else {
			31
		}
	}

	## Days from 1970-01-01 (the civil date algorithm).
	days_from_civil : I64, I64, I64 -> I64
	days_from_civil = |year, m, d| {
		y = if (m <= 2) year - 1 else year
		era = y // 400
		yoe = y - era * 400
		mp = if (m > 2) m - 3 else m + 9
		doy = (153 * mp + 2) // 5 + d - 1
		doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
		era * 146097 + doe - 719468
	}

	## The text of the answer to `Release`. The members `draft`, `prerelease`, `published_at` (a time text, `parse_time`) and `assets` must be there. A member `digest` of an
	## asset that is missing or `null` is `Err(Missing)` (the derived JSON reader cannot read `null`: see `packages/records/Nullable.roc`). Unknown members are ignored (R-AP44).
	## A text that is not JSON, a missing required member, or a bad time (R-AP57 step 5) is `Err(BadRelease)`: the handler gives 502 `upstream` (`github_bad`).
	parse_release : Str -> Try(Toolchains.Release, [BadRelease])
	parse_release = |text| {
		raw : Try(Toolchains.RawRelease, _)
		raw = Json.parse(null_digests_out(text))
		match raw {
			Ok(r) => match parse_time(r.published_at) {
				Ok(published_at) => Ok({ draft: r.draft, prerelease: r.prerelease, published_at, assets: r.assets })
				Err(BadTime) => Err(BadRelease)
			}
			Err(_) => Err(BadRelease)
		}
	}

	## The members of the GitHub release as sent. `published_at` is read as text, then `parse_time`.
	RawRelease : { draft : Bool, prerelease : Bool, published_at : Str, assets : List(Toolchains.Asset) }

	## The derived JSON reader cannot read `null` (slice 109 section 8 P2). A member `"digest":null` becomes another member, which is ignored, so the digest is missing.
	null_digests_out : Str -> Str
	null_digests_out = |text| size_whole(text.replace_each("\"digest\":null", "\"digest_null\":0").replace_each("\"digest\": null", "\"digest_null\":0"))

	## R-AP80: a member `size` that is `null`, negative or with a fraction becomes another member, which is ignored, so the size is missing.
	## Each part after `"size":` is checked: the number text runs to the first `,`, `}` or `]`.
	size_whole : Str -> Str
	size_whole = |text| {
		parts = text.replace_each("\"size\": ", "\"size\":").split_on("\"size\":")
		match parts {
			[] => text
			[first, .. as rest] => rest.fold(
				first,
				|acc, part| {
					num = part.split_on(",").first().ok_or(part).split_on("}").first().ok_or(part).split_on("]").first().ok_or(part)
					bytes = num.to_utf8()
					good = bytes.count_if(|b| b >= 48 and b <= 57) > 0 and bytes.all(|b| b >= 48 and b <= 57)
					if (good) "${acc}\"size\":${part}" else "${acc}\"size_bad\":${part}"
				},
			)
		}
	}

	# ---- the assets (R-CV2, R-CV3) ----

	## The asset of one target: the row to write.
	Picked : { target : Str, asset_name : Str, sha256 : Str, size : U64 }

	## R-CV2, R-CV3, R-CV8, R-AP57 step 6. For each target of `host_targets`, in that order: the assets whose name starts with `roc_nightly-<target>-`, ends with `archive_suffix(target)`
	## (the compare is exact, with case), is a safe path part (Design 8, R-SE18: not empty, not `.` or `..`, no `/`, no `\`, no NUL byte), and has a valid `digest` count.
	## A valid `digest` is `sha256:` and exactly 64 lower-case hex digits. An asset whose `digest` is missing, `null`, or not valid is not an asset for its host (Q109-4): it does not
	## count, also for the rule of 2 assets. R-AP80, R-AP57 step 6: an asset whose `size` is `Err(Missing)` or `Ok(0)` is not an asset for its host in the same way (also for the rule of 2 assets).
	## Exactly one asset that counts gives a `Picked` with its `size`; none, or 2 or more, give nothing for that target (the other targets stay). The date and the sha
	## in the name are not compared with the tag. An asset for another target, `roc_nightly-source-*`, and `*.wasm.zst` are not compilers. `sha256` is the hex text of `digest` without the prefix.
	select_assets : List(Toolchains.Asset) -> List(Toolchains.Picked)
	select_assets = |assets| Toolchains.host_targets.join_map(|target| picked_for(target, assets))

	## The one asset of a target, or none.
	picked_for : Str, List(Toolchains.Asset) -> List(Toolchains.Picked)
	picked_for = |target, assets| {
		prefix = "roc_nightly-${target}-"
		suffix = archive_suffix(target)
		found = assets.keep_oks(
			|a| match a.digest {
				Ok(digest) if a.name.starts_with(prefix) and a.name.ends_with(suffix) and safe_part(a.name) => match (sha256_of(digest), a.size) {
					(Ok(sha256), Ok(size)) if size > 0 => Ok({ target, asset_name: a.name, sha256, size })
					_ => Err(Skip)
				}
				_ => Err(Skip)
			},
		)
		match found {
			[one] => [one]
			_ => []
		}
	}

	## R-SE18: not empty, not `.` or `..`, no `/`, no `\`, no NUL byte.
	safe_part : Str -> Bool
	safe_part = |name| name != "" and name != "." and name != ".." and name.to_utf8().all(|b| b != 47 and b != 92 and b != 0)

	## The hex text of `sha256:<64 lower-case hex digits>`.
	sha256_of : Str -> Try(Str, [BadDigest])
	sha256_of = |digest| {
		hex = digest.drop_prefix("sha256:")
		if digest.starts_with("sha256:") and hex.count_utf8_bytes() == 64 and hex.to_utf8().all(|b| (b >= 48 and b <= 57) or (b >= 97 and b <= 102)) {
			Ok(hex)
		} else {
			Err(BadDigest)
		}
	}

	# ---- the leaf and the row to write (R-PU9, R-SG3, R-SG8, R-RE4) ----

	## R-SG3, R-SG8 rows 1 and 2: the text columns of the compiler leaf. `grp` is `roc-lang/nightlies:<target>`, `version` is the tag, `hash` is `sha256:<hex>`,
	## `time` is the time of the write (`now_ms`), not `published_at`. The leaf has no `idx`: the leaf statement computes it in SQL.
	Leaf : { grp : Str, version : Str, hash : Str, time : U64 }

	leaf_of : { target : Str, tag : Str, sha256 : Str, now_ms : U64 } -> Toolchains.Leaf
	leaf_of = |a| { grp: "roc-lang/nightlies:${a.target}", version: a.tag, hash: "sha256:${a.sha256}", time: a.now_ms }

	## The values of one pair of statements (R-SG8 row 6): the leaf statement and the `toolchains` statement. `nightly` is the id of R-IK4.
	Write : { nightly : I64, tag : Str, target : Str, asset_name : Str, sha256 : Str, size : U64, published_at : U64, leaf : Toolchains.Leaf }

	## One `Write` for each `Picked`, in the order of `picked`. `size` is the `size` of the `Picked`. The leaf has no `size` (R-AP80).
	writes_of : { tag : Str, nightly : I64, published_at : U64, now_ms : U64, picked : List(Toolchains.Picked) } -> List(Toolchains.Write)
	writes_of = |a| a.picked.map(
		|p| {
			nightly: a.nightly,
			tag: a.tag,
			target: p.target,
			asset_name: p.asset_name,
			sha256: p.sha256,
			size: p.size,
			published_at: a.published_at,
			leaf: leaf_of({ target: p.target, tag: a.tag, sha256: p.sha256, now_ms: a.now_ms }),
		},
	)

	# ---- the steps of PUT (R-AP57) ----

	## A row of `toolchains` as D1 gives it and as the wire has it (R-AP49, R-RE4, R-AP50): `target` and `asset_name` as text, `sha256` as bare hex, `size` in bytes (above 0),
	## `published_at` in ms, `log_index` of the leaf (R-AP47).
	Row : Toolchain.Row

	## Step 1: `Id.nightly_id(tag)` gave `Err(NotANightly)`: `Refuse(not_nightly(tag))` (422, no D1 call and no GitHub call). Else `ReadRows(id)`: the next action is the
	## D1 read of the rows of the id, and nothing else comes before it (Q109-1: D1 is read before GitHub).
	start : Str, Try(I64, [NotANightly]) -> [Refuse(Problem), ReadRows(I64)]
	start = |tag, id| match id {
		Ok(nightly) => ReadRows(nightly)
		Err(NotANightly) => Refuse(not_nightly(tag))
	}

	## Step 2: the rows with the id of the requested tag (`SELECT ... WHERE nightly = ?`, in `log_index` order). No row: `ReadGithub`. Each row has the requested tag:
	## `Answer(rows)` (200 with these rows, no GitHub call, R-PU9, R-PU10). A row with another tag text: `Refuse(id_taken(tag, <that tag>))`, the first such row (R-IK4: for example the
	## same nightly in the other form of CLI 6.2, R-CV1).
	after_rows : Str, List(Toolchains.Row) -> [Answer(List(Toolchains.Row)), Refuse(Problem), ReadGithub]
	after_rows = |tag, rows| match rows.find_first(|r| r.tag != tag) {
		Ok(other) => Refuse(id_taken(tag, other.tag))
		Err(NotFound) => if (rows.is_empty()) ReadGithub else Answer(rows)
	}

	## Steps 4 and 6 for a release that was read: a release with `draft` or `prerelease` true is `Err(not_final(tag))` (422, for the whole tag, Q109-3), before the assets are looked at.
	## Else `select_assets`: an empty list is `Err(no_candidate(tag))` (422). Else `Ok(picked)`.
	candidates : Str, Toolchains.Release -> Try(List(Toolchains.Picked), Problem)
	candidates = |tag, release| {
		if release.draft or release.prerelease {
			Err(not_final(tag))
		} else {
			match select_assets(release.assets) {
				[] => Err(no_candidate(tag))
				picked => Ok(picked)
			}
		}
	}

	## Step 7: the `changes` of each `toolchains` statement of the batch (the `D1.Result` info). 201 when one of them is above 0. 200 when all are 0 or the list is empty: the batch
	## wrote nothing because another request wrote the tag between the read and the batch (Q109-6). The body is then the rows of the last statement.
	put_status : List(U64) -> U16
	put_status = |changes| if (changes.any(|n| n > 0)) 201 else 200

	# ---- the list (R-AP5, R-AP47) ----

	## The query parameters as the request gives them (`Request.query`, percent-decoded).
	QueryInput : { after : Try(Str, [NotFound]), target : Try(Str, [NotFound]) }

	## `after`: the log index (0 when the parameter is missing). `target`: the filter, `Err(None)` for none.
	Query : { after : U64, target : Try(Str, [None]) }

	## R-AP56, before any D1 call (R-AP48 row 6). `after` is decimal digits only, with no leading zero (only `0` itself starts with `0`), at most 2^63 - 1; anything else
	## (empty, a sign, a point, a letter, white space, `007`, `00`, 9223372036854775808, 18446744073709551615) is `BadRequest`:
	## `the query parameter after must be a log index (decimal digits), got <text>`. No `after` is 0. `target` is any text, also an empty one or one that the registry does not
	## know: it is compared exactly with the `target` column and gives 200 with no rows (Q109-7).
	parse_query : Toolchains.QueryInput -> Try(Toolchains.Query, Problem)
	parse_query = |q| {
		after = match q.after {
			Err(NotFound) => Ok(0)
			Ok(text) => after_value(text)
		}?
		Ok({ after, target: q.target.map_err(|_| None) })
	}

	## R-AP56: decimal digits, no leading zero, at most 2^63 - 1.
	after_value : Str -> Try(U64, Problem)
	after_value = |text| {
		bad = Problem.new(BadRequest, "the query parameter after must be a log index (decimal digits), got ${text}")
		bytes = text.to_utf8()
		if bytes.is_empty() or !bytes.all(|b| b >= 48 and b <= 57) or (bytes.len() > 1 and bytes.first() == Ok(48)) {
			Err(bad)
		} else {
			match U64.from_str(text) {
				Ok(n) if n <= 9223372036854775807 => Ok(n)
				_ => Err(bad)
			}
		}
	}

	## R-AP5: the read asks for `page_limit + 1` rows with a `log_index` above `after` in the order of `log_index`. This function cuts the page:
	## the first `page_limit` rows, and `more` is true when there was a row after them.
	page_of : List(Toolchains.Row) -> { rows : List(Toolchains.Row), more : Bool }
	page_of = |rows| { rows: rows.take_first(page_limit), more: rows.len() > page_limit }

	# ---- the bodies ----

	## R-AP6: `Toolchain.encode_put` of `records` (slice 124): `{"toolchains":[<row>,...]}`. A row has the members `tag`, `target`, `asset_name`, `sha256`, `size`, `published_at`, `log_index` (R-AP80): this member order,
	## no white space, the texts escaped as JSON. The rows are in the order given.
	put_body : List(Toolchains.Row) -> Str
	put_body = |rows| Toolchain.encode_put({ toolchains: rows })

	## R-AP5: `Toolchain.encode_page`: `{"toolchains":[<row>,...],"more":<bool>}`. The same row form.
	page_body : { rows : List(Toolchains.Row), more : Bool } -> Str
	page_body = |page| Toolchain.encode_page({ toolchains: page.rows, more: page.more })

	# ---- the problems (R-AP21; the texts are proposals, slice file section 5) ----

	## 422 `not-a-candidate`: R-AP57 step 1, the tag has no nightly id.
	not_nightly : Str -> Problem
	not_nightly = |tag| Problem.new(NotACandidate, "the tag ${tag} is not a nightly tag")

	## 422 `not-a-candidate`: R-AP57 step 4, the release is a draft or a prerelease.
	not_final : Str -> Problem
	not_final = |tag| Problem.new(NotACandidate, "the release ${tag} is a draft or a prerelease")

	## 404 `not-found`: GitHub has no release with this tag.
	no_release : Str -> Problem
	no_release = |tag| Problem.new(NotFound, "roc-lang/nightlies has no release with the tag ${tag}")

	## 422 `not-a-candidate`: no asset passes R-CV1 and R-CV2.
	no_candidate : Str -> Problem
	no_candidate = |tag| Problem.new(NotACandidate, "the release ${tag} has no compiler asset (roc_nightly-<target>-*.tar.gz, or .zip for Windows)")

	## 422 `not-a-candidate`: the tag has the id of another recorded tag (R-IK4).
	id_taken : Str, Str -> Problem
	id_taken = |tag, other| Problem.new(NotACandidate, "the tag ${tag} has the same nightly id as the recorded tag ${other}")

	## 502 `upstream`: the GitHub read gave a status other than 200 and 404.
	github_status : U16 -> Problem
	github_status = |status| Problem.new(Upstream, "the GitHub release read failed with status ${status.to_str()}")

	## 502 `upstream`: no answer from GitHub.
	github_no_answer : Problem
	github_no_answer = Problem.new(Upstream, "the GitHub release read failed: no answer")

	## 502 `upstream`: the answer is not a release (`parse_release` gives `Err`, also for a `published_at` that is not in the `Z` form), or its body cannot be read.
	github_bad : Problem
	github_bad = Problem.new(Upstream, "the GitHub release answer is not a valid release")
}
