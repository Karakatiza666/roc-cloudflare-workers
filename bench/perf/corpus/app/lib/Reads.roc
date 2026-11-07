## The pure part of the read routes (Registry 4: R-AP1, R-AP2, R-AP13, R-AP14, R-AP18, R-AP24, R-AP29, R-AP32, R-AP41, R-AP43; slice 106). No effect, no platform import.
## The effects (the D1 session and its one call, the Cache API, the clock, the headers) are in `worker/ReadRoutes.roc`.
## The tests are in `worker/tests/unit/ReadsTest.roc` (W0) and `worker/tests/cases/reads/` (W2).
## The ETag, the conditional request and the cache rules are design facts: R-AP53 (answers), R-AP54 (ETag, 304, 200), R-AP55 (Cache API, `Talon-Bookmark`), R-AP56 (path and query).
## The texts of the `detail` of a problem are proposals, accepted at the review (TW24): `docs/slices/106-read-routes.md` section 6.
## Every body is built here as text, so that two answers of one state have the same bytes and the same ETag (R-AP24, R-AP49).
import records.Sorted
import records.Artifact
import records.Closure
import records.Code
import base58.Base58
import records.Id
import records.Index
import records.Release
import semver.Semver
import Problem
import Version

Reads :: [].{

	## R-AP14: at most this many releases in a page (first guess).
	page_limit : U64
	page_limit = 1000

	## R-AP1, R-AP2, R-AP13, R-AP14: the `Cache-Control` of a 200 answer and of a 304 answer. R-AP43 puts the answer in the Cache API for this time.
	cache_control : Str
	cache_control = "max-age=60"

	# ---- the ids of the request (R-IK2): bound as text by the platform (R-IK2 "Write"), so the type is I64 ----

	## The id of an artifact from its base58 hash: `Base58.decode`, exactly 32 bytes, then `Id.name_id(1, bytes)`. Anything else is `Err(BadHash)`.
	## R-AP56: a text that is no hash is 404 `not-found` with the `detail` of an unknown hash (`no_artifact`) and no D1 call. This function only tells that the text is no hash.
	artifact_id : Str -> Try(I64, [BadHash])
	artifact_id = |hash| match Base58.decode(hash) {
		Ok(bytes) => if (bytes.len() == 32) Ok(Id.name_id(1, bytes)) else Err(BadHash)
		Err(_) => Err(BadHash)
	}

	## The id of a group from its URL form: `Id.name_id(2, the UTF-8 bytes)`.
	form_id : Str -> I64
	form_id = |form| Id.name_id(2, form.to_utf8())

	## The id of a GitHub name from the two path segments (R-AP56): the ASCII letters of `<owner>/<repo>` are made lower case, then `Id.name_id(3, bytes)`.
	## So `Roc-Lang`, `Unicode` and `roc-lang`, `unicode` give one id. Only ASCII letters change.
	repo_id : Str, Str -> I64
	repo_id = |owner, repo| Id.name_id(3, "${owner}/${repo}".with_ascii_lowercased().to_utf8())

	# ---- the query of GET /v1/releases (R-AP13, R-AP14) ----

	## The three query parameters as the request gives them (`Request.query`, percent-decoded).
	QueryInput : { group : Try(Str, [NotFound]), series : Try(Str, [NotFound]), after : Try(Str, [NotFound]) }

	## `ByGroup`: R-AP13, also with `after` (R-AP14 "`after` and `group` can go together"). `ByAfter`: R-AP14 alone.
	## `series` is checked with `Version.series_bounds`. `after` is decimal digits, no leading zero (only `0` itself), at most 2^63 - 1 (R-AP56).
	Query : [ByGroup({ group : Str, series : Try(Str, [None]), after : Try(U64, [None]) }), ByAfter(U64)]

	## The first rule that fails gives `BadRequest` (R-AP48 row 6, before any D1 call):
	## 1. no `group` and no `after`: `GET /v1/releases needs the query parameter group or after`
	## 2. `group` present and empty: `the query parameter group must not be empty`
	## 3. `after` present and not in the form of R-AP56 (empty, a sign, a point, a letter, a leading zero as in `007` and `00`, above 2^63 - 1):
	##    `the query parameter after must be a log index (decimal digits), got <text>`
	## 4. `series` present and `Version.series_bounds` gives `Err(BadSeries)`: `the query parameter series must be a series (M or 0.m), got <text>`
	## R-AP56: a `series` with no `group` and no `after` is rule 1 (400). With `after` and no `group` the `series` is ignored, also a bad one: `ByAfter`.
	parse_query : Reads.QueryInput -> Try(Reads.Query, Problem)
	parse_query = |q| match q.group {
		Err(NotFound) => match q.after {
			Err(NotFound) => Err(bad_request("GET /v1/releases needs the query parameter group or after"))
			Ok(text) => after_value(text).map_ok(|n| ByAfter(n))
		}
		Ok(group) => if group == "" {
			Err(bad_request("the query parameter group must not be empty"))
		} else {
			after : Try(U64, [None])
			after = match q.after {
				Err(NotFound) => Err(None)
				Ok(text) => Ok(after_value(text)?)
			}
			series = match q.series {
				Err(NotFound) => Ok(Err(None))
				Ok(text) => match Version.series_bounds(text) {
					Ok(_) => Ok(Ok(text))
					Err(BadSeries) => Err(bad_request("the query parameter series must be a series (M or 0.m), got ${text}"))
				}
			}?
			Ok(ByGroup({ group, series, after }))
		}
	}

	# ---- the ETag and the conditional request (R-AP24) ----

	## The ETag of a body: a strong ETag, the first 16 bytes of `Crypto.SHA256.hash(body)` as 32 lower-case hex digits, in double quotes.
	etag_of : List(U8) -> Str
	etag_of = |body| {
		hex = Crypto.SHA256.hash(body).to_hex()
		"\"${Str.from_utf8_lossy(hex.to_utf8().take_first(32))}\""
	}

	## `If-None-Match` against the current ETag (RFC 9110 13.1.2, weak comparison): the value is `*`, or a comma separated list of entity tags.
	## A tag `W/"x"` matches `"x"`. White space around a tag is ignored. A text that is no tag never matches (so `abc` does not match `"abc"`).
	etag_matches : Str, Str -> Bool
	etag_matches = |if_none_match, etag| {
		value = if_none_match.trim()
		if value == "*" {
			Bool.True
		} else {
			value.split_on(",").any(|item| strong_part(item.trim()) == etag)
		}
	}

	# ---- the cache decision and the session (R-AP43, R-AP41 row 5) ----

	## R-AP43: true when the request must not read the Cache API: the `Cache-Control` request header has the directive `no-cache`
	## (comma separated list, no case, white space around a directive ignored, the whole directive: `no-cachex` is not it), or the `Pragma`
	## request header has the directive `no-cache` (same list rule). R-AP55: no other directive counts (`max-age=0`, `no-store`, `private`), and no other header (`Expires`).
	bypass_cache : { cache_control : Try(Str, [NotFound]), pragma : Try(Str, [NotFound]) } -> Bool
	bypass_cache = |h| has_no_cache(h.cache_control) or has_no_cache(h.pragma)

	## R-AP41 row 5: the value of the request header `Talon-Bookmark` gives `After(<the value with white space cut>)`. No header, or an empty value: `Any`.
	session_of : Try(Str, [NotFound]) -> [Any, After(Str)]
	session_of = |bookmark| match bookmark {
		Ok(text) => if (text.trim() == "") Any else After(text.trim())
		Err(NotFound) => Any
	}

	# ---- checked (R-AP29) and repos (R-AP32) ----

	## R-PU22 (first guesses): 1 hour for a repository with no App installation, 24 hours for one with the App.
	interval_ms : Bool -> U64
	interval_ms = |app_installed| if (app_installed) 86_400_000 else 3_600_000

	## R-AP29: stale when `checked_at` is `Err(None)` (never read since the first ingest), or `now_ms - checked_at` is more than 2 intervals.
	## Exactly 2 intervals is not stale. A `checked_at` after `now_ms` is not stale.
	stale : { checked_at : Try(U64, [None]), app_installed : Bool, now_ms : U64 } -> Bool
	stale = |c| match c.checked_at {
		Err(None) => Bool.True
		Ok(at) => c.now_ms > at and c.now_ms - at > 2 * interval_ms(c.app_installed)
	}

	## The row of `repo_checks` joined with the name of the repo (`names.value`, kind 3).
	CheckRow : { name : Str, checked_at : Try(U64, [Missing]), app_installed : Bool }

	## An item of `checked` (R-AP29): `{name, checked_at, stale}`. It is the type of `records` (slice 104b).
	CheckedItem : Closure.Checked

	checked_of_row : Reads.CheckRow, U64 -> Reads.CheckedItem
	checked_of_row = |row, now_ms| {
		checked_at = row.checked_at.map_err(|_| None)
		{ name: row.name, checked_at, stale: stale({ checked_at, app_installed: row.app_installed, now_ms }) }
	}

	## The row of `repos` joined with the names of the repo and of the successor (`names.value`, kind 3). `state` is the code 0, 1, 2.
	RepoRow : { name : Str, state : I64, successor : Try(Str, [Missing]), state_at : U64 }

	## An item of `repos` (R-AP32): `{name, state, successor, state_at}`. `state` is `active`, `missing` or `moved` on the wire. It is the type of `records` (slice 104b).
	RepoItem : Closure.Repo

	## A `state` that is not 0, 1 or 2 is `Err(BadRow)`.
	repo_item_of_row : Reads.RepoRow -> Try(Reads.RepoItem, [BadRow(Str)])
	repo_item_of_row = |row| {
		state = match row.state {
			0 => Ok(Active)
			1 => Ok(Missing)
			2 => Ok(Moved)
			other => Err(BadRow("repo ${row.name}: the state code ${I64.to_str(other)} is not known"))
		}?
		Ok({ name: row.name, state, successor: row.successor.map_err(|_| None), state_at: row.state_at })
	}

	# ---- the rows of releases and artifacts ----

	## One release as a D1 row (the SQL of the route joins `names`): `hash` is `names.value` of the artifact (a BLOB, the 32 bytes of the hash; it reads into
	## `List(U8)` with the `--opt=speed` build, slice file D106-1), `form` is `names.value`
	## of `releases.form`, `version` is `CAST(version AS TEXT)`, `repo` is `names.value` of `releases.repo` (kind 3), `yanked` is 0 or 1.
	ReleaseRow : {
		log_index : U64,
		hash : List(U8),
		form : Str,
		version : Str,
		version_text : Str,
		url : Str,
		tag : Try(Str, [Missing]),
		roc_version : Try(Str, [Missing]),
		repo : Try(Str, [Missing]),
		published_at : U64,
		yanked : Bool,
		withdrawn : Try(Str, [Missing]),
		vias : Try(Str, [Missing]),
	}

	## Slice 122, R-AP49 `provenance`, R-PU15, R-RE9: the `via` texts of the provenance rows of a release, strongest first. `vias` is the column `vias` of the row: the codes of `provenance.via`
	## (R-RE9: `oidc` 0, `webhook` 1, `poll` 2, `ingest` 3) as decimal digits with a comma between them, in any order, for example `3,0`. NULL (`Err(Missing)`) when the release has no row.
	## The result has the texts of `Code.via_name`, in the order of `Code.via_sort`: `3,0` gives `["oidc", "ingest"]`. A code that is not 0 to 3, and a text that is not a list of codes, is `Err(BadRow(text))`.
	## No row (`Err(Missing)`) is the question Q122-1 of the slice file: until the human answers it, the result is `Err(BadRow(text))`.
	provenance_of : Try(Str, [Missing]) -> Try(List(Str), [BadRow(Str)])
	provenance_of = |vias| match vias {
		# Q341: a release with no row has the empty list.
		Err(Missing) => Ok([])
		Ok(text) => Ok(Code.via_sort(text.split_on(",").map_try(via_of_item)?))
	}

	via_of_item : Str -> Try(Str, [BadRow(Str)])
	via_of_item = |item| {
		code = U8.from_str(item).map_err(|_| BadRow("provenance: ${item} is not a via code"))?
		Code.via_name(code).map_err(|_| BadRow("provenance: the via code ${item} is not known"))
	}

	## The wire record of R-AP49. `provenance`: `provenance_of(row.vias)` (slice 122; a stub gives `[]` until the code agent writes it). `hash`: `Base58.encode` of the 32 bytes; another length is `BadRow`. `group`: `form`. `version` and `series`: `Version.read`, then
	## `Semver.to_str` and `Version.series_of`. `yank_reason`: always `Err(None)` before P3 (`yanks` is P3). The nullable columns are `Err(None)` when missing.
	## A hash with other than 32 bytes, or a version column that `Version.read` refuses, is `Err(BadRow)` with a text (the handler gives 500 `internal`, R-AP48).
	release_of_row : Reads.ReleaseRow -> Try(Release.Row, [BadRow(Str)])
	release_of_row = |row| {
		hash = base58_of_bytes(row.hash)?
		version = Version.read({ version: row.version, version_text: row.version_text }).map_err(|_| BadRow("release ${U64.to_str(row.log_index)}: the version column is not valid"))?
		Ok({
			log_index: row.log_index,
			hash,
			group: row.form,
			series: Version.series_of(version),
			version: version.to_str(),
			url: row.url,
			tag: row.tag.map_err(|_| None),
			roc_version: row.roc_version.map_err(|_| None),
			repo: row.repo.map_err(|_| None),
			published_at: row.published_at,
			yanked: row.yanked,
			yank_reason: Err(None),
			withdrawn: row.withdrawn.map_err(|_| None),
			provenance: provenance_of(row.vias)?,
		})
	}

	## One artifact as D1 rows. `kind` is the code 0, 1, 2. `exposed_json` is `artifacts.exposes`: a JSON array of text in the order of the header (R-RE1). `hash` and `platform_hash` are `names.value` (the 32 bytes) as for `ReleaseRow`.
	ArtifactRow : { hash : List(U8), kind : I64, exposed_json : Str, platform_hash : Try(List(U8), [Missing]), roc_pin : Try(Str, [Missing]), size : U64 }

	## One row of `deps` with `hash` = `names.value` of `dep` (the 32 bytes), `form` = `names.value` of `deps.form`, `version` = `CAST(version AS TEXT)`.
	## `is_platform` is `deps.platform` (0 or 1, selected `AS is_platform`: `platform` is a reserved word of Roc), R-AP81.
	## `form` and `version` are NULL together (R-RE19). R-AP49: a dep with no `form` has `group` made from `url`: no scheme, no last segment (`<hash>.tar.zst`),
	## no `{v}`. Example: `https://example.com/pkg/lib/<hash>.tar.zst` gives `example.com/pkg/lib/`. Its `series` and `version` are `Err(None)`.
	DepRow : { alias : Str, hash : List(U8), form : Try(Str, [Missing]), version : Try(Str, [Missing]), version_text : Try(Str, [Missing]), url : Str, is_platform : Bool }

	## The artifact record of R-AP49 from its rows. `target_names` are the `targets.name` of `artifact_targets`. `kind` code to `Code.Kind` (an unknown code is `BadRow`).
	## `deps` series and version: as `release_of_row`, `Err(None)` when `version` is missing. The sort of deps and targets is done by `Artifact.encode`.
	artifact_of_rows : { artifact : Reads.ArtifactRow, deps : List(Reads.DepRow), target_names : List(Str) } -> Try(Artifact.Row, [BadRow(Str)])
	artifact_of_rows = |rows| {
		row = rows.artifact
		hash = base58_of_bytes(row.hash)?
		kind = match row.kind {
			0 => Ok(App)
			1 => Ok(Package)
			2 => Ok(Platform)
			other => Err(BadRow("artifact ${hash}: the kind code ${I64.to_str(other)} is not known"))
		}?
		exposed : Try(List(Str), _)
		exposed = Json.parse(row.exposed_json)
		platform_hash = match row.platform_hash {
			Ok(text) => Ok(base58_of_bytes(text)?)
			Err(Missing) => Err(None)
		}
		deps = rows.deps.map_try(dep_of_row)?
		Ok({
			hash,
			kind,
			exposed: exposed.map_err(|_| BadRow("artifact ${hash}: exposes is not a JSON array of text"))?,
			platform_hash,
			roc_pin: row.roc_pin.map_err(|_| None),
			size: row.size,
			deps,
			target_names: rows.target_names,
		})
	}

	# ---- the bodies (R-AP1, R-AP13, R-AP14, R-AP2) ----

	## R-AP1 and R-AP13 (R-AP53): `Index.encode_releases` of `records` (slice 124): `{"releases":[<Release.encode each>],"checked":<item or null>,"repos":[<items>]}`. No white space.
	## The items of `repos` are sorted by `name` (bytes) here, because the encoder writes the lists in the order given (R-AP53).
	releases_body : { releases : List(Release.Row), checked : Try(Reads.CheckedItem, [None]), repos : List(Reads.RepoItem) } -> Str
	releases_body = |a| Index.encode_releases({ releases: a.releases, checked: a.checked, repos: sorted_repos(a.repos) })

	## R-AP14 without a group: `Index.encode_page`: `{"releases":[..],"repos":[..]}`.
	page_body : { releases : List(Release.Row), repos : List(Reads.RepoItem) } -> Str
	page_body = |a| Index.encode_page({ releases: a.releases, repos: sorted_repos(a.repos) })

	## R-AP2 (R-AP53): `Index.encode_detail`: `{"artifact":<Artifact.encode>,"releases":[..],"repos":[..]}`.
	artifact_body : { artifact : Artifact.Row, releases : List(Release.Row), repos : List(Reads.RepoItem) } -> Str
	artifact_body = |a| Index.encode_detail({ artifact: a.artifact, releases: a.releases, repos: sorted_repos(a.repos) })

	# ---- the problems of the three routes (R-AP21) ----

	## R-AP1, 404: `no indexed release for <owner>/<repo>` (the two path segments as sent).
	no_repo_releases : Str, Str -> Problem
	no_repo_releases = |owner, repo| Problem.new(NotFound, "no indexed release for ${owner}/${repo}")

	## R-AP2, 404: `no artifact <hash>` (the path segment as sent).
	no_artifact : Str -> Problem
	no_artifact = |hash| Problem.new(NotFound, "no artifact ${hash}")

	# ---- helpers (private use) ----

	bad_request : Str -> Problem
	bad_request = |detail| Problem.new(BadRequest, detail)

	max_after : U64
	max_after = 9223372036854775807

	## R-AP56: decimal digits, no leading zero (only `0` itself), at most 2^63 - 1.
	after_value : Str -> Try(U64, Problem)
	after_value = |text| {
		bytes = text.to_utf8()
		digits = !bytes.is_empty() and bytes.all(|b| b >= '0' and b <= '9')
		plain = bytes.len() == 1 or bytes.first() != Ok('0')
		number = if (digits and plain) U64.from_str(text).map_err(|_| BadNumber) else Err(BadNumber)
		match number {
			Ok(n) if n <= max_after => Ok(n)
			_ => Err(bad_request("the query parameter after must be a log index (decimal digits), got ${text}"))
		}
	}

	## The tag of an entity tag with the weak mark `W/` cut (RFC 9110 13.1.2 weak comparison).
	strong_part : Str -> Str
	strong_part = |tag| tag.drop_prefix("W/")

	## R-AP55: the directive `no-cache` in a comma separated list, no case, white space around a directive ignored.
	has_no_cache : Try(Str, [NotFound]) -> Bool
	has_no_cache = |header| match header {
		Ok(text) => text.split_on(",").any(|item| item.trim().caseless_ascii_equals("no-cache"))
		Err(NotFound) => Bool.False
	}

	## The 32 bytes of a hash become its base58 text (R-IK1). Another length is `BadRow`.
	base58_of_bytes : List(U8) -> Try(Str, [BadRow(Str)])
	base58_of_bytes = |bytes| if (bytes.len() == 32) Ok(Base58.encode(bytes)) else Err(BadRow("a hash has ${U64.to_str(bytes.len())} bytes, not 32"))

	## R-AP49: one dep. With a `form`, its group is `form`. Without one, the group is made from `url`.
	dep_of_row : Reads.DepRow -> Try(Artifact.Dep, [BadRow(Str)])
	dep_of_row = |dep| {
		hash = base58_of_bytes(dep.hash)?
		column = match dep.version {
			Ok(version) => Ok(Version.read({ version, version_text: dep.version_text ?? "" }))
			Err(Missing) => Err(None)
		}
		version : Try(Semver, [None])
		version = match column {
			Ok(read) => Ok(read.map_err(|_| BadRow("dep ${dep.alias}: the version column is not valid"))?)
			Err(None) => Err(None)
		}
		Ok({
			alias: dep.alias,
			hash,
			group: match dep.form {
				Ok(form) => form
				Err(Missing) => group_of_url(dep.url)
			},
			series: version.map_ok(Version.series_of),
			version: version.map_ok(|v| v.to_str()),
			url: dep.url,
			is_platform: dep.is_platform,
		})
	}

	## R-AP49 (Q106-8): the URL with no scheme and no last segment.
	group_of_url : Str -> Str
	group_of_url = |url| {
		rest = match url.split_on("://") {
			[_, .. as after] => Str.join_with(after, "://")
			_ => url
		}
		"${Str.join_with(rest.split_on("/").drop_last(1), "/")}/"
	}

	## R-AP53: `repos` sorted by `name` (bytes).
	sorted_repos : List(Reads.RepoItem) -> List(Reads.RepoItem)
	sorted_repos = |repos| Sorted.sort_with(repos, |a, b| Artifact.compare(a.name, b.name))
}
