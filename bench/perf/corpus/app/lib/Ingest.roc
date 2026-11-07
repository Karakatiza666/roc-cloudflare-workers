## The pure part of the ingest route `POST /v1/releases` with no token (Registry 4: R-AP9, R-AP26, R-AP41; 5.1: R-IK3; 7: R-PU4, R-PU6, R-PU14, R-PU15,
## R-PU19, R-PU26, R-PU31, R-PU32, R-PU34 rows 3 and 4, R-TP5; slice 112). No effect, no platform import.
## The effects (the body read, the D1 session and its calls, the GitHub reads, the archive read, the clock) are in `worker/IngestRoutes.roc`.
## The tests are in `worker/tests/unit/IngestTest.roc` (W0) and `worker/tests/cases/ingest/` (W2).
## The texts of the `detail` of a problem and the body form are proposals (TW24): `docs/slices/112-ingest.md` section 5.
import records.Sorted
import base58.Base58
import header.PackageUrl
import records.Artifact
import records.Code
import records.Id
import records.Release
import semver.Semver
import Problem
import Reads
import Toolchains
import Version

Ingest :: [].{

	# ---- the request ----

	## The release that the URL names (R-DI5, R-PU6). `url` is the request URL as sent. `owner`, `repo` and `tag` are the path parts as sent.
	## `name` is `<owner>/<repo>` with the ASCII letters in lower case (R-IK2, R-RE11). `hash` is the base58 hash of the last segment.
	## `form` is `PackageUrl.url_form` (the group, R-AP15). `version` is the `X.Y.Z` run of the URL. `column` is `Version.column(version)` (R-IK5).
	Target : { url : Str, owner : Str, repo : Str, name : Str, tag : Str, hash : Str, form : Str, version : Semver, column : Version.Column }

	## R-AP26, R-AP48 row 6, R-AP51. The body is a JSON object with the member `url` (text, required). The first rule that fails gives the problem:
	## 1. Not JSON, not an object, `url` missing, `null` or not text: 400 `bad-request` (`bad_body`).
	## 2. A member `compat` with a value that is not `null` (any JSON value): 401 `unauthenticated` (`compat_needs_token`). `compat: null` is no value (R-AP51): an ingest.
	## Other members are ignored (R-AP44). The result is the text of `url`.
	parse_body : List(U8) -> Try(Str, Problem)
	parse_body = |bytes| {
		not_object = bad_body("the body is not a JSON object with a text member url")
		if bytes.is_empty() {
			return Err(bad_body("the body is empty"))
		}
		text = Str.from_utf8(bytes).map_err(|_| not_object)?
		parsed : Try({ url : Str }, _)
		parsed = Json.parse(text)
		match parsed {
			Err(_) => Err(not_object)
			Ok(b) => if (top_values(bytes, "compat").any(|v| v != "null")) Err(compat_needs_token) else Ok(b.url)
		}
	}

	## The texts of the values of the top-level members `name` of a JSON object (white space cut). The text is valid JSON (the derived read has passed it).
	## A member name with an escape is read with `Json.parse`, so `"\u0063ompat"` is `compat`.
	top_values : List(U8), Str -> List(Str)
	top_values = |bytes, name| {
		var $depth = 0.U64
		var $in_str = Bool.False
		var $esc = Bool.False
		var $want_key = Bool.True
		var $start = 0.U64
		var $key = ""
		var $out = []
		var $i = 0.U64
		for b in bytes {
			if $in_str {
				if $esc {
					$esc = Bool.False
				} else if b == '\\' {
					$esc = Bool.True
				} else if b == '"' {
					$in_str = Bool.False
					if $depth == 1 and $want_key {
						$key = key_text(bytes.sublist({ start: $start, len: $i + 1 - $start }))
					}
				}
			} else if b == '"' {
				$in_str = Bool.True
				$start = if ($depth == 1 and $want_key) $i else $start
			} else if b == '{' or b == '[' {
				$depth = $depth + 1
			} else if b == '}' or b == ']' {
				if $depth == 1 and !$want_key and $key == name {
					$out = $out.append(value_text(bytes, $start, $i))
				}
				$depth = $depth - 1
			} else if $depth == 1 and b == ':' {
				$want_key = Bool.False
				$start = $i + 1
			} else if $depth == 1 and b == ',' {
				if $key == name {
					$out = $out.append(value_text(bytes, $start, $i))
				}
				$want_key = Bool.True
				$key = ""
			}
			$i = $i + 1
		}
		$out
	}

	key_text : List(U8) -> Str
	key_text = |quoted| {
		text = Str.from_utf8_lossy(quoted)
		parsed : Try(Str, _)
		parsed = Json.parse(text)
		parsed ?? text
	}

	value_text : List(U8), U64, U64 -> Str
	value_text = |bytes, start, end| Str.from_utf8_lossy(bytes.sublist({ start, len: end - start })).trim()

	## R-PU34 row 4, R-DI5, R-PU6. The URL must be `https://github.com/<owner>/<repo>/releases/download/<tag>/<hash>.tar.zst`: exactly these 7 path parts after the host,
	## each part not empty, with no query and no fragment, `<hash>` base58 of exactly 32 bytes, and `PackageUrl.parse` gives `Ok` (one `X.Y.Z` run, not `0.0.0`).
	## Else 422 `not-a-candidate` (`not_release_url`). Another host is also `not_release_url`, with no D1 call and no GitHub call (R-PU40, Design Q155; R-AP68 row 2).
	parse_url : Str -> Try(Ingest.Target, Problem)
	parse_url = |url| {
		refuse = Err(not_release_url(url))
		if url.contains("?") or url.contains("#") {
			return refuse
		}
		match url.split_on("/") {
			["https:", "", "github.com", owner, repo, "releases", "download", tag, file] if owner != "" and repo != "" and tag != "" and file.ends_with(".tar.zst") => {
				hash = file.drop_suffix(".tar.zst")
				match (hash_bytes(hash), PackageUrl.parse(url)) {
					(Ok(_), Ok(p)) => {
						v = p.version()
						version = Semver.new(v.major, v.minor, v.patch)
						name = "${owner}/${repo}".with_ascii_lowercased()
						Ok({ url, owner, repo, name, tag, hash, form: p.url_form(), version, column: Version.column(version) })
					}
					_ => refuse
				}
			}
			_ => refuse
		}
	}

	## The 32 bytes of a base58 hash. Another text is `Err(BadHash)`.
	hash_bytes : Str -> Try(List(U8), [BadHash])
	hash_bytes = |hash| match Base58.decode(hash) {
		Ok(bytes) if bytes.len() == 32 => Ok(bytes)
		_ => Err(BadHash)
	}

	## The GitHub reads, in this order (R-AP68 rows 6, 8, 10; Design Q156). The parts are put in the URL as they are in the request URL.
	repo_url : Ingest.Target -> Str
	repo_url = |t| "https://api.github.com/repos/${t.owner}/${t.repo}"

	release_url : Ingest.Target -> Str
	release_url = |t| "https://api.github.com/repos/${t.owner}/${t.repo}/releases/tags/${t.tag}"

	## R-AP49 `roc_version`, CLI R-DI8.
	roc_version_url : Ingest.Target -> Str
	roc_version_url = |t| "https://raw.githubusercontent.com/${t.owner}/${t.repo}/${t.tag}/.roc-version"

	# ---- the pre-read (D1 call 1, R-AP41 "an optional read batch") ----

	## The release row of the label (form, version, version_text) of the target, if it has one, and if it has a `provenance` row with `via` = `ingest` (code 3, R-RE9).
	LabelRow : { release : Reads.ReleaseRow, has_ingest : Bool }

	## What to do after the pre-read (R-AP68 rows 4 and 7; Design Q156, Q157):
	## - `Conflict(problem)`: the label has another hash (R-PU19): 409 `label_conflict(target, Ok(<the other hash>))`. No GitHub read, no write.
	## - `Answer(release)`: the label has this hash and an `ingest` provenance row (R-PU14): 200 with the record. No GitHub read, no write.
	## - `AddProvenance(log_index)`: the label has this hash, and no `ingest` row: the visibility read (R-PU31), then a batch with the provenance row only (R-PU15), 200.
	## - `Index`: no row for the label: the whole flow.
	## A row that `Reads.release_of_row` refuses, or a hash that is not 32 bytes, is `Err(BadRow)` (500).
	after_read : Ingest.Target, List(Ingest.LabelRow) -> Try([Conflict(Problem), Answer(Release.Row), AddProvenance(U64), Index], [BadRow(Str)])
	after_read = |target, rows| match rows {
		[] => Ok(Index)
		[row, ..] => {
			release = Reads.release_of_row(row.release)?
			if release.hash != target.hash {
				Ok(Conflict(label_conflict(target, Ok(release.hash))))
			} else if row.has_ingest {
				Ok(Answer(release))
			} else {
				Ok(AddProvenance(release.log_index))
			}
		}
	}

	# ---- the GitHub answers ----

	## `GET /repos/{owner}/{repo}` (R-PU31, R-TP5): `id`, `owner.id`, and `public` when `visibility` is `public` (R-PU32: `private` and `internal` are not).
	## A text that is not JSON, or with a member missing, is `Err(BadRepo)` (502). Unknown members are ignored.
	Repo : { id : U64, owner_id : U64, public : Bool }

	parse_repo : Str -> Try(Ingest.Repo, [BadRepo])
	parse_repo = |text| {
		parsed : Try({ id : U64, owner : { id : U64 }, visibility : Str }, _)
		parsed = Json.parse(text)
		match parsed {
			Ok(r) => Ok({ id: r.id, owner_id: r.owner.id, public: r.visibility == "public" })
			Err(_) => Err(BadRepo)
		}
	}

	## `GET /repos/{owner}/{repo}/releases/tags/{tag}` (R-PU6): `draft`, `prerelease`, `published_at` (`Toolchains.parse_time`; `null` or missing is `Err(None)`),
	## and the `name` of each asset. A text that is not JSON, a missing `draft`, `prerelease` or `assets`, or a `published_at` text that `parse_time` refuses, is `Err(BadRelease)` (502).
	GithubRelease : { draft : Bool, prerelease : Bool, published_at : Try(U64, [None]), assets : List(Str) }

	parse_release : Str -> Try(Ingest.GithubRelease, [BadRelease])
	parse_release = |text| {
		# The derived JSON reader cannot read `null` (as `Toolchains.null_digests_out`): `"published_at":null` becomes another member, so the member is missing.
		cleaned = text.replace_each("\"published_at\":null", "\"published_at_null\":0").replace_each("\"published_at\": null", "\"published_at_null\":0")
		parsed : Try({ draft : Bool, prerelease : Bool, published_at : Try(Str, [Missing]), assets : List({ name : Str }) }, _)
		parsed = Json.parse(cleaned)
		match parsed {
			Err(_) => Err(BadRelease)
			Ok(r) => {
				published_at = match r.published_at {
					Ok(time) => Ok(Toolchains.parse_time(time).map_err(|_| BadRelease)?)
					Err(Missing) => Err(None)
				}
				Ok({ draft: r.draft, prerelease: r.prerelease, published_at, assets: r.assets.map(|a| a.name) })
			}
		}
	}

	## R-PU6 with CLI R-DI3 and R-DI4. The first rule that fails gives the problem:
	## 1. `draft`: 422 `not_final(tag, "a draft")`. 2. `prerelease`: 422 `not_final(tag, "a prerelease")`.
	## 3. The package assets are the assets named `<b>.tar.zst` with `<b>` base58 of exactly 32 bytes (`x.tar.zst.intoto.jsonl`, `docs.tar.gz` are not).
	##    0 of them: 422 `no_package_asset`. 2 or more: 422 `many_package_assets(tag, count)`.
	## 4. The one package asset is not `<hash>.tar.zst` of the URL: 422 `other_asset(tag, name)`.
	## 5. `published_at` is `Err(None)`: 502 `github_bad("release")`.
	## The result is `published_at` in ms.
	candidate : Ingest.Target, Ingest.GithubRelease -> Try(U64, Problem)
	candidate = |target, release| {
		found = release.assets.keep_if(is_package_asset)
		if release.draft {
			Err(not_final(target.tag, "a draft"))
		} else if release.prerelease {
			Err(not_final(target.tag, "a prerelease"))
		} else {
			match found {
				[] => Err(no_package_asset(target.tag))
				[one] if one != "${target.hash}.tar.zst" => Err(other_asset(target.tag, one))
				[_] => release.published_at.map_err(|_| github_bad("release"))
				_ => Err(many_package_assets(target.tag, found.len()))
			}
		}
	}

	is_package_asset : Str -> Bool
	is_package_asset = |name| name.ends_with(".tar.zst") and hash_bytes(name.drop_suffix(".tar.zst")).is_ok()

	## The text of `.roc-version` at the tag (R-AP49): no white space at the ends.
	roc_version_of : Str -> Str
	roc_version_of = |text| text.trim()

	# ---- the write batch (D1 call 2, R-SG8, R-IK3, R-PU15, R-PU26, R-TP5) ----

	## One `names` row (R-IK3, R-RE22). `value`: the 32 hash bytes for kind 1 (bound as a blob), the UTF-8 bytes of the text for kinds 2 and 3 (bound as text).
	Name : { id : I64, kind : U8, value : List(U8) }

	## The rows of one ingest. Each id is a function of its name (R-IK2: `Id.name_id`). The batch writes them in the order of the slice file section 3.2.
	## - `names`: each name that a row of the plan refers to, once, sorted by `id`: the artifact hash, the platform hash (an app), each dep hash and each dep form
	##   (a dep with a version), the form of the release, the lower-case GitHub name.
	## - `new_targets`: the target names of the artifact with no code yet (`Code.target_code` gives `Err`), in the order of `artifact.target_names` (R-IK7).
	## - `artifact` (R-RE1): `kind` is the code (R-IK7), `exposes_json` the JSON array of the module names in header order (Q106-7), `platform_id` the id of `platform_hash`.
	## - `deps` (R-RE19): in the order of `artifact.deps` sorted by `alias`. `form` and `version` are `Err(None)` for a dep URL with no version. `is_platform` is `d.is_platform` (R-AP81; the statement writes it as `deps.platform`, 1 or 0).
	## - `target_names` (R-RE20): `artifact.target_names`, sorted.
	## - `leaf` (R-SG8 rows 1 and 2): `grp` the form, `version` `Semver.to_str`, `hash` the base58 hash, `time` the clock of the request.
	## - `release` (R-RE2): `repo` the id of `name`, `url` and `tag` of the target, `published_at` of GitHub. `yanked` 0, `withdrawn` NULL.
	## - `provenance_time` (R-PU15): `via` 3 (`ingest`), no claims, this time (the clock).
	## - `repo_row` (R-TP5): a new `repos` row, state `active` (0), no successor, `state_at` and `time` the clock. Not written when the row exists (slice 113 compares the ids, R-TP9).
	## - `check_row` (R-PU26, R-PU22): a new `repo_checks` row: `etag` and `checked_at` NULL, `next_check_at` = the clock + `Reads.interval_ms(Bool.False)` (1 h),
	##   `fail_count` 0, `app_installed` 0. Not written when the row exists.
	Plan : {
		names : List(Ingest.Name),
		new_targets : List(Str),
		artifact : { id : I64, kind : U8, exposes_json : Str, platform_id : Try(I64, [None]), roc_pin : Try(Str, [None]), size : U64 },
		deps : List({ alias : Str, dep : I64, form : Try(I64, [None]), version : Try(Version.Column, [None]), url : Str, is_platform : Bool }),
		target_names : List(Str),
		leaf : { grp : Str, version : Str, hash : Str, time : U64 },
		release : { form : I64, column : Version.Column, artifact : I64, repo : I64, url : Str, tag : Str, roc_version : Try(Str, [None]), published_at : U64 },
		provenance_time : U64,
		repo_row : { repo : I64, repository_id : U64, repository_owner_id : U64, time : U64 },
		check_row : { repo : I64, next_check_at : U64 },
	}

	plan : { target : Ingest.Target, repo : Ingest.Repo, artifact : Artifact.Row, published_at : U64, roc_version : Try(Str, [None]), now_ms : U64 } -> Ingest.Plan
	plan = |input| {
		t = input.target
		a = input.artifact
		hash_name = |h| { id: 0, kind: 1, value: hash_bytes(h) ?? [] }
		text_name = |kind, text| { id: 0, kind, value: text.to_utf8() }
		deps = Sorted.sort_with(a.deps, |x, y| Artifact.compare(x.alias, y.alias))
		dep_names = deps.join_map(
			|d| match d.version {
				Ok(_) => [hash_name(d.hash), text_name(2, d.group)]
				Err(None) => [hash_name(d.hash)]
			},
		)
		platform_names = match a.platform_hash {
			Ok(h) => [hash_name(h)]
			Err(None) => []
		}
		all = [hash_name(a.hash)].concat(platform_names).concat(dep_names).concat([text_name(2, t.form), text_name(3, t.name)])
		unique = all
			.map(|n| { ..n, id: Id.name_id(n.kind, n.value) })
			.fold([], |acc, n| if (acc.any(|m| m.id == n.id)) acc else acc.append(n))
		names = Sorted.sort_with(unique, |x, y| x.id.order_relative_to(y.id))
		id_of_hash = |h| Id.name_id(1, hash_bytes(h) ?? [])
		artifact_id = id_of_hash(a.hash)
		repo = Id.name_id(3, t.name.to_utf8())
		{
			names,
			new_targets: a.target_names.keep_if(|n| Code.target_code(n).is_err()),
			artifact: {
				id: artifact_id,
				kind: Code.kind_code(a.kind),
				exposes_json: Json.to_str(a.exposed),
				platform_id: a.platform_hash.map_ok(id_of_hash),
				roc_pin: a.roc_pin,
				size: a.size,
			},
			deps: deps.map(
				|d| {
					version = d.version.map_ok(|text| Semver.parse(text).map_ok(Version.column))
					match version {
						Ok(Ok(c)) => { alias: d.alias, dep: id_of_hash(d.hash), form: Ok(Reads.form_id(d.group)), version: Ok(c), url: d.url, is_platform: d.is_platform }
						_ => { alias: d.alias, dep: id_of_hash(d.hash), form: Err(None), version: Err(None), url: d.url, is_platform: d.is_platform }
					}
				},
			),
			target_names: Sorted.sort_with(a.target_names, Artifact.compare),
			leaf: { grp: t.form, version: t.version.to_str(), hash: t.hash, time: input.now_ms },
			release: {
				form: Reads.form_id(t.form),
				column: t.column,
				artifact: artifact_id,
				repo,
				url: t.url,
				tag: t.tag,
				roc_version: input.roc_version,
				published_at: input.published_at,
			},
			provenance_time: input.now_ms,
			repo_row: { repo, repository_id: input.repo.id, repository_owner_id: input.repo.owner_id, time: input.now_ms },
			check_row: { repo, next_check_at: input.now_ms + Reads.interval_ms(Bool.False) },
		}
	}

	# ---- the batch result ----

	## The constraint failure of `D1.batch!` (the platform `Sql.Constraint`, the same shape: lib/ has no platform import).
	Constraint : { kind : [PrimaryKey, Unique, ForeignKey, Check, NotNull, Trigger, Datatype, Other], message : Str }

	## `Trigger` with the message `label-conflict` (R-SG8 row 4, Q27): `LabelConflict` (409, `label_conflict(target, Err(None))`, R-AP68 row 11, Design Q164).
	## `PrimaryKey` with the message `UNIQUE constraint failed: names.id` (R-IK3): `IdCollision` (D1 call 3, then `collision`).
	## Each other failure (also `leaf-missing`, R-SG8 row 7, and a `PrimaryKey` of another table): `Fault` (500).
	batch_failure : Ingest.Constraint -> [LabelConflict, IdCollision, Fault]
	batch_failure = |c| match c.kind {
		Trigger if c.message == "label-conflict" => LabelConflict
		PrimaryKey if c.message == "UNIQUE constraint failed: names.id" => IdCollision
		_ => Fault
	}

	## One row of the detail read of R-IK3: `SELECT CAST(id AS TEXT) AS id, kind, CAST(value AS BLOB) AS value FROM names WHERE id IN (...)` with the ids of `plan.names`.
	NameRow : { id : Str, kind : I64, value : List(U8) }

	## R-IK3: the first name of `names` (in its order) for which a row has the same id and another (kind, value) gives 409 `id_collision(new, other)`.
	## A name is shown as text: kind 1 as base58, kinds 2 and 3 as UTF-8. With no such row (it cannot be), 409 `id_collision_unknown`.
	collision : List(Ingest.Name), List(Ingest.NameRow) -> Problem
	collision = |names, rows| {
		found = names.fold_until(
			Err(None),
			|acc, n| {
				other = rows.find_first(|r| r.id == n.id.to_str() and (r.kind != n.kind.to_i64() or r.value != n.value))
				match other {
					Ok(r) => Break(Ok(id_collision((n.kind, name_text(n.kind, n.value)), (r.kind.to_u8_wrap(), name_text(r.kind.to_u8_wrap(), r.value)), r.id)))
					Err(NotFound) => Continue(acc)
				}
			},
		)
		found ?? id_collision_unknown
	}

	## A name as text (R-IK3): kind 1 as base58, kinds 2 and 3 as UTF-8.
	name_text : U8, List(U8) -> Str
	name_text = |kind, value| if (kind == 1) Base58.encode(value) else Str.from_utf8_lossy(value)

	## R-AP8: 201 when the `releases` statement of the batch has `changes` above 0, else 200 (another request wrote the label between the 2 calls, as Q109-6).
	status_of : U64 -> U16
	status_of = |release_changes| if (release_changes > 0) 201 else 200

	## The body of a 200 or 201 answer (R-AP8, TW24 proposal): `{"release":<Release.encode of the record>}`, no white space.
	answer_body : Release.Row -> Str
	answer_body = |release| "{\"release\":${Release.encode(release)}}"

	## R-AP8: the `Location` of a 201 answer.
	location : Str -> Str
	location = |hash| "/v1/artifacts/${hash}"

	## R-AP9: the `Cache-Control` of a 200 and a 201 answer.
	cache_control : Str
	cache_control = "no-store"

	# ---- the problems (R-AP21; the texts are proposals, slice file section 5) ----

	bad_body : Str -> Problem
	bad_body = |why| Problem.new(BadRequest, "the body must be a JSON object with the member url (text): ${why}")

	compat_needs_token : Problem
	compat_needs_token = Problem.new(Unauthenticated, "a body with compat needs a GitHub OIDC token (tln publish)")

	not_release_url : Str -> Problem
	not_release_url = |url| Problem.new(NotACandidate, "the url is not a GitHub release asset URL with a version and a hash (https://github.com/<owner>/<repo>/releases/download/<tag>/<hash>.tar.zst): ${url}")

	## R-PU32: the design gives this `detail`.
	not_public : Problem
	not_public = Problem.new(NotACandidate, "repository not found or not public")

	no_release : Str -> Problem
	no_release = |tag| Problem.new(NotACandidate, "the repository has no published release with the tag ${tag}")

	not_final : Str, Str -> Problem
	not_final = |tag, what| Problem.new(NotACandidate, "the release ${tag} is ${what}")

	no_package_asset : Str -> Problem
	no_package_asset = |tag| Problem.new(NotACandidate, "the release ${tag} has no package asset <hash>.tar.zst")

	many_package_assets : Str, U64 -> Problem
	many_package_assets = |tag, n| Problem.new(NotACandidate, "the release ${tag} has ${n.to_str()} package assets <hash>.tar.zst, not 1")

	other_asset : Str, Str -> Problem
	other_asset = |tag, name| Problem.new(NotACandidate, "the package asset of the release ${tag} is ${name}, not the asset of the url")

	## R-PU19: the detail says to release a new version. `other` is the hash in the index when the pre-read saw it, `Err(None)` after a race (R-AP68, Design Q164).
	label_conflict : Ingest.Target, Try(Str, [None]) -> Problem
	label_conflict = |t, other| {
		seen : Str
		seen = match other {
			Ok(h) => Str.concat("the hash ", h)
			Err(None) => "another hash"
		}
		Problem.new(LabelConflict, "the label ${t.form} ${t.version.to_str()} has ${seen} in the index, not ${t.hash}: release a new version")
	}

	## R-IK3: `new` and `other` are (kind, text). Kind words: 1 `hash`, 2 `group`, 3 `repository`.
	id_collision : (U8, Str), (U8, Str), Str -> Problem
	id_collision = |(nk, new), (ok, other), id| Problem.new(IdCollision, "the ${kind_word(nk)} ${new} has the id ${id} of the ${kind_word(ok)} ${other} in the index")

	id_collision_unknown : Problem
	id_collision_unknown = Problem.new(IdCollision, "a name of the release has the id of another name in the index")

	kind_word : U8 -> Str
	kind_word = |k| match k {
		1 => "hash"
		2 => "group"
		_ => "repository"
	}

	## 502 `upstream`: `what` is `repository`, `release` or `.roc-version`.
	github_status : Str, U16 -> Problem
	github_status = |what, status| Problem.new(Upstream, "the GitHub ${what} read failed with status ${status.to_str()}")

	github_no_answer : Str -> Problem
	github_no_answer = |what| Problem.new(Upstream, "the GitHub ${what} read failed: no answer")

	github_bad : Str -> Problem
	github_bad = |what| Problem.new(Upstream, "the GitHub ${what} answer is not valid")
}
