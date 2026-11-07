import Artifact
import Closure
import Nullable
import Release

## The answers of the release reads (Registry R-AP1, R-AP2, R-AP13, R-AP14, R-AP53, R-AP73; slice 104e). Pure.
## The encoders write the bytes of `worker/lib/Reads.roc` (`releases_body`, `page_body`, `artifact_body`): no white space, the members in the order below, the lists in the order given (the caller sorts, R-AP53), a release by `Release.encode`, a `repos` item by `Closure.encode_repo`, a `checked` item by `Closure.encode_checked`.
## The decoders follow R-AP51: a required member that is missing or `null` is `BadJson`, an unknown member is ignored. `checked` is required and may be `null`.
Index :: [].{

	## R-AP1, R-AP13, R-AP14 with `group`. Members in this order: `releases`, `checked` (one item or `null`), `repos`.
	Releases : { releases : List(Release.Row), checked : Try(Closure.Checked, [None]), repos : List(Closure.Repo) }

	## R-AP14 with no `group`. Members: `releases`, `repos`.
	Page : { releases : List(Release.Row), repos : List(Closure.Repo) }

	## R-AP2. Members: `artifact`, `releases`, `repos`.
	Detail : { artifact : Artifact.Row, releases : List(Release.Row), repos : List(Closure.Repo) }

	## The wire forms (the nested records are the wire forms of their modules).
	ReleasesWire : { releases : List(Release.Wire), checked : Nullable(Closure.CheckedWire), repos : List(Closure.RepoWire) }
	PageWire : { releases : List(Release.Wire), repos : List(Closure.RepoWire) }
	DetailWire : { artifact : Artifact.Wire, releases : List(Release.Wire), repos : List(Closure.RepoWire) }

	list : List(Str) -> Str
	list = |items| "[${Str.join_with(items, ",")}]"

	releases_text : List(Release.Row) -> Str
	releases_text = |rows| list(rows.map(Release.encode))

	repos_text : List(Closure.Repo) -> Str
	repos_text = |repos| list(repos.map(Closure.encode_repo))

	bad_json : _ -> [BadJson(Str)]
	bad_json = |e| BadJson(Str.inspect(e))

	repos_of : List(Closure.RepoWire) -> Try(List(Closure.Repo), [BadJson(Str)])
	repos_of = |wires| wires.map_try(Closure.repo_from_wire)

	encode_releases : Index.Releases -> Str
	encode_releases = |a| {
		checked = match a.checked {
			Ok(c) => Closure.encode_checked(c)
			Err(None) => "null"
		}
		"{\"releases\":${releases_text(a.releases)},\"checked\":${checked},\"repos\":${repos_text(a.repos)}}"
	}

	decode_releases : Str -> Try(Index.Releases, [BadJson(Str)])
	decode_releases = |text| {
		parsed : Try(Index.ReleasesWire, _)
		parsed = Json.parse(text)
		w = parsed.map_err(bad_json)?
		Ok({ releases: w.releases.map(Release.from_wire), checked: Nullable.read(w.checked).map_ok(Closure.checked_from_wire), repos: repos_of(w.repos)? })
	}

	encode_page : Index.Page -> Str
	encode_page = |a| "{\"releases\":${releases_text(a.releases)},\"repos\":${repos_text(a.repos)}}"

	decode_page : Str -> Try(Index.Page, [BadJson(Str)])
	decode_page = |text| {
		parsed : Try(Index.PageWire, _)
		parsed = Json.parse(text)
		w = parsed.map_err(bad_json)?
		Ok({ releases: w.releases.map(Release.from_wire), repos: repos_of(w.repos)? })
	}

	encode_detail : Index.Detail -> Str
	encode_detail = |a| "{\"artifact\":${Artifact.encode(a.artifact)},\"releases\":${releases_text(a.releases)},\"repos\":${repos_text(a.repos)}}"

	decode_detail : Str -> Try(Index.Detail, [BadJson(Str)])
	decode_detail = |text| {
		parsed : Try(Index.DetailWire, _)
		parsed = Json.parse(text)
		w = parsed.map_err(bad_json)?
		Ok({ artifact: Artifact.from_wire(w.artifact)?, releases: w.releases.map(Release.from_wire), repos: repos_of(w.repos)? })
	}
}
