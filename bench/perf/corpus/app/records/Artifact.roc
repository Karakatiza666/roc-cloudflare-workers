import Code
import Sorted
import Nullable

## One artifact on the wire (Registry R-RE1, R-RE19, R-RE20, R-AP2, R-AP17). Pure.
## The wire members are the table of R-AP49. `exposes`, `platform` and `targets` are reserved words in Roc, so they cannot be record fields: the wire names are the field names below, with no renaming in the codec.
Artifact :: [].{

	## One dependency (R-RE19). `alias` is the name in the header. `hash` is the base58 hash of the dependency. `group` as in R-AP15. `series` and `version` are `Err(None)` (null) when the URL has no version. `is_platform` (slice 104i, R-AP81, R-AP49) is `true` for the platform entry of a package or platform header, `false` for each other dep. It is required on the wire (R-AP51) and written after `hash` (alphabetical order). The wire name is `is_platform` because `platform` is a reserved word in Roc.
	Dep : { alias : Str, hash : Str, group : Str, series : Try(Str, [None]), version : Try(Str, [None]), url : Str, is_platform : Bool }

	## `exposed` is the list of module names of R-RE1 `exposes`. `kind` is the kind of the header as text (`app`, `package`, `platform` on the wire; an unknown value is `BadJson`, R-AP51). `platform_hash` is the hash of the platform artifact, `Err(None)` (null) for a kind with no platform. `roc_pin` is the `roc:` pin of a platform or an app, `Err(None)` for none. `target_names` are the target names (R-RE20). `size` is the bytes of the `.tar.zst` asset. `encode` sorts `deps` by `alias` and `target_names` (R-AP49).
	Row : {
		hash : Str,
		kind : Code.Kind,
		exposed : List(Str),
		platform_hash : Try(Str, [None]),
		roc_pin : Try(Str, [None]),
		size : U64,
		deps : List(Artifact.Dep),
		target_names : List(Str),
	}

	## The wire form of a dep and of a row (`kind` as text, nullable members as `Nullable(Str)`).
	DepWire : { alias : Str, hash : Str, group : Str, series : Nullable(Str), version : Nullable(Str), url : Str, is_platform : Bool }
	Wire : {
		hash : Str,
		kind : Str,
		exposed : List(Str),
		platform_hash : Nullable(Str),
		roc_pin : Nullable(Str),
		size : U64,
		deps : List(Artifact.DepWire),
		target_names : List(Str),
	}

	## Order of two texts by their bytes.
	compare : Str, Str -> [Before, Same, After]
	compare = |a, b| compare_bytes(a.to_utf8(), b.to_utf8())

	compare_bytes : List(U8), List(U8) -> [Before, Same, After]
	compare_bytes = |x, y| match (x, y) {
		([], []) => Same
		([], _) => Before
		(_, []) => After
		([p, .. as rx], [q, .. as ry]) => if (p < q) Before else if (p > q) After else compare_bytes(rx, ry)
	}

	## R-AP49: `deps` are sorted by `alias` and `target_names` by text.
	to_wire : Artifact.Row -> Artifact.Wire
	to_wire = |r| {
		hash: r.hash,
		kind: match r.kind {
			App => "app"
			Package => "package"
			Platform => "platform"
		},
		exposed: r.exposed,
		platform_hash: Nullable.write(r.platform_hash),
		roc_pin: Nullable.write(r.roc_pin),
		size: r.size,
		deps: Sorted.sort_with(r.deps, |a, b| compare(a.alias, b.alias)).map(|d| { alias: d.alias, hash: d.hash, group: d.group, series: Nullable.write(d.series), version: Nullable.write(d.version), url: d.url, is_platform: d.is_platform }),
		target_names: Sorted.sort_with(r.target_names, compare),
	}

	from_wire : Artifact.Wire -> Try(Artifact.Row, [BadJson(Str)])
	from_wire = |w| {
		kind = match w.kind {
			"app" => Ok(App)
			"package" => Ok(Package)
			"platform" => Ok(Platform)
			other => Err(BadJson("unknown kind ${other}"))
		}?
		Ok({
			hash: w.hash,
			kind,
			exposed: w.exposed,
			platform_hash: Nullable.read(w.platform_hash),
			roc_pin: Nullable.read(w.roc_pin),
			size: w.size,
			deps: w.deps.map(|d| { alias: d.alias, hash: d.hash, group: d.group, series: Nullable.read(d.series), version: Nullable.read(d.version), url: d.url, is_platform: d.is_platform }),
			target_names: w.target_names,
		})
	}

	decode : Str -> Try(Artifact.Row, [BadJson(Str)])
	decode = |text| {
		parsed : Try(Artifact.Wire, _)
		parsed = Json.parse(text)
		match parsed {
			Ok(wire) => from_wire(wire)
			Err(e) => Err(BadJson(Str.inspect(e)))
		}
	}

	encode : Artifact.Row -> Str
	encode = |row| Json.to_str(to_wire(row))
}
