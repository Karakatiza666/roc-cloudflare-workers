import tar.Tar
import records.Sorted
import header.Header
import header.PackageUrl
import base58.Base58
import records.Artifact
import records.Code
import Problem

## The archive read of a package asset (Registry R-PU38, Design 2, R-GA2, R-PK5, R-PK8; slice 111). Pure: the steps of one read and their checks.
## `worker/Archive.roc` (`Archive.read!`) orders the effects: the HTTP read, `Native.Blake3` and `Native.ZstdStream`. The tests are W0 (`worker/tests/unit/ArchiveReadTest.roc`)
## and W2 (`worker/tests/cases/archive/`, through the test app `worker/archive-test.roc`).
##
## The state holds only the packed byte count, the tar reader, the header file `main.roc`, the paths, and the first refusal (R-PU38 row 1). It never holds a chunk.
##
## | Step | Function | Rule |
## | --- | --- | --- |
## | Before the body read | `check_length` of the `Content-Length` header | Row 2 |
## | Each packed chunk, before any other work on it | `count` with the chunk length. `Err(TooLarge)` stops the read at once: no more hash, no more decode. | Row 2 |
## | Each decoded chunk, while `reading` is true | `push`: the tar reader (`tar_limits`, `choose`), and for each member: the kind, `Tar.check_portable_path`, a duplicate key, a member below a file | Rows 5, 6, 7, 12, 17 |
## | A zstd error (push or close) | `unzip_failed` | Row 3 (`WindowTooLarge`), row 10 |
## | The end of the body | `finish` with the 32 digest bytes and the hash of the URL | Rows 4 to 7, R-RE1, R-RE19, R-RE20 |
##
## After a refusal of `push` or `unzip_failed`, `reading` is false: the effect code gives no more bytes to the zstd decoder and the tar reader, but it still reads the
## body to its end and gives each chunk to BLAKE3 and to `count` (row 4: "the header read can end early, but the hash reads to the end").
## The tar can also end (two zero blocks) before the body ends: `reading` stays true, and `push` takes the zero bytes after the end (roc-tar accepts them).
##
## The order of the refusals that `finish` gives (row 9): a hash that is not the hash of the URL first, then the first refusal of the read, then the end
## check of the tar (`Tar.finish`), then no header file, then the header. `TooLarge` of `count` never reaches `finish`.
ArchiveRead :: {
	# The backing fields are private: the code agent can change them. The functions below are fixed.
	packed : U64,
	# Q441: the count of all decoded bytes given to `push` (members, headers, padding, the zeros after the tar end), kept between chunks.
	decoded : U64,
	tar : Tar,
	header : Try(List(U8), [None]),
	# Only the paths below `targets/` (for `target_names`).
	paths : List(Str),
	# The path keys of the members, the file members (key to path), and the dirs above the members (key to the path of the first member below).
	seen : Set(Str),
	files : Dict(Str, Str),
	below : Dict(Str, Str),
	refused : Try(ArchiveRead.Refusal, [None]),
}.{

	## Row 2: the most bytes of the `.tar.zst` asset. 100 MB is 100,000,000 bytes (row 15).
	max_packed_bytes : U64
	max_packed_bytes = 100000000

	## Row 3: the largest zstd window, the hard limit of `Native.ZstdStream` (its default). `Archive.read!` opens the stream with `open!` (the default limit).
	max_window_bytes : U64
	max_window_bytes = 8388608

	## Row 5: the unpacked total (256 MiB), the members, the bytes of one path (as `roc unbundle`), and the header file (1 MiB).
	max_unpacked_bytes : U64
	max_unpacked_bytes = 268435456

	max_members : U64
	max_members = 10000

	max_path_bytes : U64
	max_path_bytes = 255

	max_header_bytes : U64
	max_header_bytes = 1048576

	## Q441, row 5: the most decoded bytes of one read, all of them (members, headers, padding and the zeros after the tar end): `max_unpacked_bytes` + 16 MiB for the headers and the padding.
	## Over it: `TooLargeUnpacked(max_decoded_bytes)`. Equal to it passes.
	max_decoded_bytes : U64
	max_decoded_bytes = 285212672

	## Slice 123 (platform 0.0.3): the most output bytes of one `Native.ZstdStream.feed!` call, so a chunk with a high ratio (a long run of zeros) never makes a list of more than this.
	## 64 KiB, the size of a `Body.chunk!` chunk.
	feed_bytes : U64
	feed_bytes = 65536

	## Row 7: the header file is the member `main.roc` at the archive root.
	header_path : Str
	header_path = "main.roc"

	## Why the asset is not a candidate (R-PU6). `problem` gives the problem of each.
	Refusal : [
		# Row 2. `from`: the `Content-Length` header (before the read) or the count of the bytes read (at the chunk that went over the limit).
		TooLarge({ bytes : U64, from : [ContentLength, Count] }),
		# Row 2: a `Content-Length` of digits over the U64 range. The payload is the header text as sent.
		TooLargeHeader(Str),
		# Row 3
		WindowTooLarge,
		# Row 10: the other zstd errors of `Native.ZstdStream`
		BadZstd([BadFrame, Truncated, Unsupported, OutputLimit]),
		# Row 5, Q441: the decoded bytes of the read (all of them) are over the limit. The payload is the limit (`max_decoded_bytes`).
		TooLargeUnpacked(U64),
		# Rows 5 and 6: a limit or a strict error of roc-tar
		BadTar(Tar.Error),
		# Row 6: a path that `Tar.check_portable_path` refuses
		BadPath({ path : Str, problem : [EmptyPath, TooLong, Absolute, DriveLetter, ParentDir, DotPart, ReservedName, EndsWithSpace, EndsWithPeriod, ReservedChar(U8), Backslash] }),
		# Rows 6, 12: a member that is not a file (type `0` or NUL) or a dir (type `5`). roc-tar gives `File` also for type `7` (contiguous): that member is
		# `NotAFile({ path, kind: Other('7') })` (roc-tar 0.0.2 gives the type byte as `entry.type_byte`).
		NotAFile({ path : Str, kind : Tar.Kind }),
		# Row 17: a member whose `path_key` is the key of a member before it. The payload is the path of the later member, as in the archive.
		Duplicate(Str),
		# Row 17: a member below a file member: `path` is the member below (the file `a` and the member `a/b`, in any order), `file` is the file. Paths as in the archive.
		UnderFile({ path : Str, file : Str }),
		# Row 7: no member `main.roc`
		NoHeader,
		# Rows 7, 16, Design R-PK5: `main.roc` is not UTF-8, or `Header.parse` refuses it. An app with no platform is accepted (row 16).
		BadHeader([NotUtf8, NoHeader, BadHeader(U64)]),
		# Row 14: a `deps` entry that does not start with `https://`, that `PackageUrl.parse` refuses (except `NoVersion`), or whose hash is not base58 of 32 bytes.
		BadDep({ alias : Str, url : Str }),
		# Row 13, Design Q400: 2 or more platform entries in the header (roc refuses them: `multiple_platforms`). The payload is the aliases of the platform entries, in header order.
		MultiplePlatforms(List(Str)),
		# Row 4
		HashMismatch({ expected : Str, actual : Str }),
	]

	## The fields of the header (R-RE1, R-RE19, R-AP49, row 13). `exposed` is empty for an app. `platform_hash` is the hash of the platform URL of an app (`None` for an app
	## with no platform, row 16, and for a package and a platform). `roc_pin` is the value of the entry `roc`. `deps` has one item for each other entry, in header order:
	## not the platform entry of an app, not `roc`. A platform entry of a package or a platform header is a `deps` item with `is_platform` `true` (row 13, R-AP81). Each other dep has `false`. Two or more platform entries (any kind) are `MultiplePlatforms`.
	Fields : { kind : Code.Kind, exposed : List(Str), platform_hash : Try(Str, [None]), roc_pin : Try(Str, [None]), deps : List(Artifact.Dep) }

	## The limits of the tar reader (row 5): `max_members`, `max_path_bytes`, `max_unpacked_bytes` as `max_total_size`. The other limits are the defaults of roc-tar.
	tar_limits : Tar.Limits
	tar_limits = Tar.Limits.{ max_members: 10000, max_path_bytes: 255, max_total_size: 268435456 }

	## The choice of the tar reader for each member: `Collect(max_header_bytes)` for a file whose path key with no case fold is `main.roc` (row 17:
	## `main.roc`, `main.roc/` is a dir, `MAIN.ROC` is not the header), `Skip` for each other member.
	choose : Tar.Entry -> Tar.Action
	choose = |entry| if (entry.kind == File and Str.join_with(parts(entry.path), "/") == header_path) Collect(max_header_bytes) else Skip

	## The state before the first chunk.
	empty : () -> ArchiveRead
	empty = || {
		packed: 0,
		decoded: 0,
		tar: Tar.new(tar_limits),
		header: Err(None),
		paths: [],
		seen: Set.empty(),
		files: Dict.empty(),
		below: Dict.empty(),
		refused: Err(None),
	}

	## The hash text of an asset URL: the last path segment with no `.tar.zst` (Design 2). `NoHash` when the URL has no such segment.
	url_hash : Str -> Try(Str, [NoHash])
	url_hash = |url| {
		last = url.split_on("/").last() ?? ""
		hash = last.drop_suffix(".tar.zst")
		if (last.ends_with(".tar.zst") and hash != "") Ok(hash) else Err(NoHash)
	}

	## Row 2, before the read: the value of `Content-Length`. No header passes (the count still applies). A value of decimal digits over `max_packed_bytes` is
	## `TooLarge({ bytes, from: ContentLength })`. A value that is not decimal digits passes (proposal: workerd checks the framing; the count still applies).
	check_length : Try(Str, [NotFound]) -> Try({}, ArchiveRead.Refusal)
	check_length = |value| match value {
		Ok(text) if text != "" and text.to_utf8().all(|b| b >= '0' and b <= '9') => {
			# A run of digits that does not fit in a U64 is over the limit too.
			match U64.from_str(text) {
				Ok(bytes) => if (bytes > max_packed_bytes) Err(TooLarge({ bytes, from: ContentLength })) else Ok({})
				Err(_) => Err(TooLargeHeader(text))
			}
		}

		_ => Ok({})
	}

	## Row 2, while the read goes on: add the bytes of one packed chunk. Over `max_packed_bytes` in all is `TooLarge({ bytes: <the new total>, from: Count })`.
	count : ArchiveRead, U64 -> Try(ArchiveRead, ArchiveRead.Refusal)
	count = |state, bytes| {
		total = state.packed + bytes
		if (total > max_packed_bytes) Err(TooLarge({ bytes: total, from: Count })) else Ok({ ..state, packed: total })
	}

	## True while no refusal is kept: the effect code gives the decoded bytes to `push` only then.
	reading : ArchiveRead -> Bool
	reading = |state| state.refused.is_err()

	## Give decoded bytes (any size, also empty) to the tar reader. For each member (`Entry` event), in this order: a kind that is not `File` or `Dir`, or type `7`,
	## is `NotAFile` (row 12); a path that `Tar.check_portable_path` refuses is `BadPath`; a `path_key` seen before is `Duplicate`; a member below a file, or a file
	## above a member seen before, is `UnderFile` (row 17). An error of `Tar.push` is `BadTar`.
	## The first refusal is kept, and the state reads no more bytes. The `Content` of `main.roc` is the header file.
	## Q441: the bytes are counted first, all of them, with the count kept in the state between calls. A total over `max_decoded_bytes` is `TooLargeUnpacked`:
	## the tar reader never gets the chunk that crosses the limit, and the state reads no more.
	push : ArchiveRead, List(U8) -> ArchiveRead
	push = |state, bytes| {
		if !reading(state) {
			return state
		}
		total = state.decoded + bytes.len()
		if total > max_decoded_bytes {
			return { ..state, decoded: total, refused: Ok(TooLargeUnpacked(max_decoded_bytes)) }
		}
		tar_push({ ..state, decoded: total }, bytes)
	}

	# The tar reader part of `push`. The bytes are counted already.
	tar_push : ArchiveRead, List(U8) -> ArchiveRead
	tar_push = |state, bytes| {
		if !reading(state) {
			return state
		}
		match state.tar.push(bytes, choose) {
			Ok((tar, events)) => {
				next = { ..state, tar }
				events.fold(next, |s, event| if (reading(s)) on_event(s, event) else s)
			}

			# roc-tar gives no events before its error. A second read in blocks of 512 bytes gives the members before the error,
			# so that the first refusal is in stream order (row 9) for each chunk size.
			Err(_) if bytes.len() > 512 => bytes.chunks_of(512).fold(state, |s, piece| tar_push(s, piece))
			Err(e) => { ..state, refused: Ok(BadTar(e)) }
		}
	}

	## Keep a zstd error of `Native.ZstdStream.push!` or `close!`: `WindowTooLarge` (row 3), else `BadZstd`. A refusal kept before stays.
	unzip_failed : ArchiveRead, [OutputLimit, WindowTooLarge, BadFrame, Truncated, Unsupported] -> ArchiveRead
	unzip_failed = |state, err| {
		refusal = match err {
			WindowTooLarge => WindowTooLarge
			OutputLimit => BadZstd(OutputLimit)
			BadFrame => BadZstd(BadFrame)
			Truncated => BadZstd(Truncated)
			Unsupported => BadZstd(Unsupported)
		}
		if (reading(state)) { ..state, refused: Ok(refusal) } else state
	}

	## The end of the read: the 32 bytes of the BLAKE3 digest and the hash of the URL. The order of the checks is in the module comment.
	## `Ok` gives the artifact record: `hash` (the hash of the URL), `size` (the packed byte count), the `Fields`, and `target_names`.
	finish : ArchiveRead, List(U8), Str -> Try(Artifact.Row, ArchiveRead.Refusal)
	finish = |state, digest, hash| {
		actual = Base58.encode(digest)
		if actual != hash {
			return Err(HashMismatch({ expected: hash, actual }))
		}
		match state.refused {
			Ok(refusal) => return Err(refusal)
			Err(None) => {}
		}
		_ = state.tar.finish() ? BadTar
		header = state.header ? |_| NoHeader
		fields = header_fields(header)?
		Ok({
			hash,
			kind: fields.kind,
			exposed: fields.exposed,
			platform_hash: fields.platform_hash,
			roc_pin: fields.roc_pin,
			size: state.packed,
			deps: fields.deps,
			target_names: target_names(fields.kind, state.paths),
		})
	}

	## Row 7, R-PK5, R-RE1, R-RE19, R-AP49: the fields of the bytes of `main.roc`, with `Header.parse` of roc-app-header and `PackageUrl.parse` for each dep.
	## A dep URL that `PackageUrl.parse` reads gives the group `url_form`, the series and the version `X.Y.Z`. A URL with no version (`NoVersion`) gives the group of
	## R-AP49 (the URL with no scheme and no last segment), and no series and no version. Row 14: a dep that does not start with `https://`, each other error of
	## `PackageUrl.parse`, and a hash that `Base58.decode` does not give as 32 bytes are `BadDep`.
	header_fields : List(U8) -> Try(ArchiveRead.Fields, ArchiveRead.Refusal)
	header_fields = |bytes| {
		text = Str.from_utf8(bytes) ? |_| BadHeader(NotUtf8)
		header = match Header.parse(text) {
			Ok(h) => h
			Err(NoHeader) => return Err(BadHeader(NoHeader))
			Err(BadHeader({ offset })) => return Err(BadHeader(BadHeader(offset)))
		}
		kind = match header.kind() {
			App => App
			Package => Package
			Platform(_) => Platform
		}
		var $platform_hash = Err(None)
		var $roc_pin = Err(None)
		var $deps = []
		var $platforms = []
		for entry in header.entries() {
			if entry.name == "roc" and !entry.is_platform {
				$roc_pin = Ok(entry.value)
			} else if entry.is_platform and kind == App {
				# Row 18: the platform URL of an app gets the checks of a dep (row 14).
				$platform_hash = Ok(dep_of(entry.name, entry.value, entry.is_platform)?.hash)
			} else {
				$deps = $deps.append(dep_of(entry.name, entry.value, entry.is_platform)?)
			}
			if entry.is_platform {
				$platforms = $platforms.append(entry.name)
			}
		}
		if $platforms.len() >= 2 {
			return Err(MultiplePlatforms($platforms))
		}
		exposed = if (kind == App) [] else header.exposed()
		Ok({ kind, exposed, platform_hash: $platform_hash, roc_pin: $roc_pin, deps: $deps })
	}

	## Row 17: the key of a member path: the parts between `/` with no empty part, joined by `/`, each ASCII `A` to `Z` as `a` to `z`. `a//b`, `a/b/` and `A/B` have the key `a/b`.
	path_key : Str -> Str
	path_key = |path| Str.join_with(parts(path), "/").with_ascii_lowercased()

	## R-RE20, R-IK7: the target names of a platform: for each path `targets/<name>/<more>`, the `<name>` when it matches `[a-z0-9]{1,32}`
	## (`Code.is_new_target_name`, or a known target). Distinct, sorted by bytes. Empty for an app and a package. A name that does not match (`macos-sysroot`) is skipped (row 11).
	target_names : Code.Kind, List(Str) -> List(Str)
	target_names = |kind, paths| {
		if kind != Platform {
			return []
		}
		names = paths.fold(
			Set.empty(),
			|set, path| match target_of(path) {
				Ok(name) => set.insert(name)
				Err(None) => set
			},
		)
		Sorted.sort_with(names.to_list(), Artifact.compare)
	}

	## The problem of a refusal (R-AP21): 422 `not-a-candidate` with the `detail` of the slice file (section 5) for each refusal. `HashMismatch` too (row 8).
	problem : ArchiveRead.Refusal -> Problem
	problem = |refusal| Problem.new(NotACandidate, detail(refusal))

	## The problem of a failed asset read: 502 `upstream` (a proposal; slice 112 can map a 404 in another way).
	upstream_problem : [Status(U16), NoAnswer, BodyRead] -> Problem
	upstream_problem = |err| {
		text = match err {
			Status(status) => "the asset read failed with status ${status.to_str()}"
			NoAnswer => "the asset read failed: no answer"
			BodyRead => "the asset read failed: the body stopped"
		}
		Problem.new(Upstream, text)
	}
}

# The parts of a path between `/`, with no empty part (row 17).
parts : Str -> List(Str)
parts = |path| path.split_on("/").keep_if(|part| part != "")

# The keys of the dirs above a key: `a/b/c` gives `a` and `a/b`.
above : Str -> List(Str)
above = |key| {
	ps = key.split_on("/")
	var $dirs = []
	for n in 1.U64..<ps.len() {
		$dirs = $dirs.append(Str.join_with(ps.take_first(n), "/"))
	}
	$dirs
}

# The checks of one event of the tar reader (rows 6, 12, 17).
on_event : ArchiveRead, Tar.Event -> ArchiveRead
on_event = |state, event| match event {
	Content(_, data) => { ..state, header: Ok(data) }
	Entry(entry) => match check_member(state, entry) {
		Ok(next) => next
		Err(refusal) => { ..state, refused: Ok(refusal) }
	}
}

check_member : ArchiveRead, Tar.Entry -> Try(ArchiveRead, ArchiveRead.Refusal)
check_member = |state, entry| {
	path = entry.path
	# roc-tar gives `File` also for type 7 (contiguous). The type byte of the header is `entry.type_byte` since roc-tar 0.0.2 (row 12).
	# `Tar.roc_accepts` is not used: it accepts a symbolic link with a safe target, and row 12 refuses each symbolic link.
	kind = if (entry.kind == File and entry.type_byte == '7') Other('7') else entry.kind
	match kind {
		File | Dir => {}
		_ => return Err(NotAFile({ path, kind }))
	}
	Tar.check_portable_path(path) ? |problem| BadPath({ path, problem })
	key = ArchiveRead.path_key(path)
	if state.seen.contains(key) {
		return Err(Duplicate(path))
	}
	dirs = above(key)
	for dir in dirs {
		match state.files.get(dir) {
			Ok(file) => return Err(UnderFile({ path, file }))
			Err(_) => {}
		}
	}
	is_file = kind == File
	if is_file {
		match state.below.get(key) {
			Ok(under) => return Err(UnderFile({ path: under, file: path }))
			Err(_) => {}
		}
	}
	Ok({
		..state,
		seen: state.seen.insert(key),
		files: if (is_file) state.files.insert(key, path) else state.files,
		below: dirs.fold(state.below, |d, dir| if (d.contains(dir)) d else d.insert(dir, path)),
		paths: if (path.starts_with("targets/")) state.paths.append(path) else state.paths,
	})
}

# One `deps` row (row 14, R-RE19, R-AP49).
dep_of : Str, Str, Bool -> Try(Artifact.Dep, ArchiveRead.Refusal)
dep_of = |alias, url, is_platform| {
	bad = BadDep({ alias, url })
	if !url.starts_with("https://") {
		return Err(bad)
	}
	dep = match PackageUrl.parse(url) {
		Ok(u) => {
			v = u.version()
			{ alias, hash: u.hash(), group: u.url_form(), series: Ok(u.series()), version: Ok("${v.major.to_str()}.${v.minor.to_str()}.${v.patch.to_str()}"), url, is_platform }
		}

		Err(NoVersion) => {
			hash = ArchiveRead.url_hash(url) ? |_| bad
			group = url.drop_prefix("https://").drop_suffix("${hash}.tar.zst")
			{ alias, hash, group, series: Err(None), version: Err(None), url, is_platform }
		}

		Err(_) => return Err(bad)
	}
	match Base58.decode(dep.hash) {
		Ok(raw) if raw.len() == 32 => Ok(dep)
		_ => Err(bad)
	}
}

# The target name of a path `targets/<name>/<more>` (R-RE20, R-IK7, row 11).
target_of : Str -> Try(Str, [None])
target_of = |path| match parts(path) {
	["targets", name, ..] if Code.is_new_target_name(name) and (parts(path).len() > 2 or path.ends_with("/")) => Ok(name)
	_ => Err(None)
}

detail : ArchiveRead.Refusal -> Str
detail = |refusal| match refusal {
	TooLarge({ bytes, from: ContentLength }) => "the asset has ${bytes.to_str()} bytes (Content-Length), more than the limit of ${ArchiveRead.max_packed_bytes.to_str()} bytes"
	TooLarge({ bytes, from: Count }) => "the asset has more than the limit of ${ArchiveRead.max_packed_bytes.to_str()} bytes (the read stopped at ${bytes.to_str()} bytes)"
	TooLargeHeader(text) => "the asset has more than ${ArchiveRead.max_packed_bytes.to_str()} bytes (Content-Length ${text})"
	WindowTooLarge => "the zstd window of the asset is larger than ${ArchiveRead.max_window_bytes.to_str()} bytes"
	BadZstd(err) => {
		why = match err {
			BadFrame => "a damaged frame"
			Truncated => "the stream ends inside a frame"
			Unsupported => "a frame needs a dictionary"
			OutputLimit => "a block gives too many bytes"
		}
		"the asset is not a valid zstd stream: ${why}"
	}

	TooLargeUnpacked(limit) => "the unpacked archive has more than ${limit.to_str()} bytes"
	BadTar(err) => Tar.err_to_str(err)
	BadPath({ path, problem }) => "the archive has a path that roc unbundle refuses (${path_why(problem)}): ${path}"
	NotAFile({ path, kind }) => "the archive has ${kind_text(kind)}, not a file: ${path}"
	Duplicate(path) => "the archive has the path ${path} two times"
	UnderFile({ path, file }) => "the archive has ${path} below the file ${file}"
	NoHeader => "the archive has no main.roc at its root"
	BadHeader(err) => {
		why = match err {
			NotUtf8 => "it is not UTF-8"
			NoHeader => "it starts with no app, package or platform header"
			BadHeader(offset) => "the header stops to be valid at byte ${offset.to_str()}"
		}
		"main.roc has no valid header: ${why}"
	}

	BadDep({ alias, url }) => "main.roc has a header entry ${alias} that is not a package URL with a hash: ${url}"
	MultiplePlatforms(aliases) => "main.roc has more than one platform entry (roc refuses it: multiple_platforms): ${Str.join_with(aliases, ", ")}"
	HashMismatch({ expected, actual }) => "the BLAKE3 hash of the asset is ${actual}, not the hash ${expected} of the URL"
}

path_why : [EmptyPath, TooLong, Absolute, DriveLetter, ParentDir, DotPart, ReservedName, EndsWithSpace, EndsWithPeriod, ReservedChar(U8), Backslash] -> Str
path_why = |problem| match problem {
	EmptyPath => "empty"
	TooLong => "more than 255 bytes"
	Absolute => "absolute"
	DriveLetter => "a drive letter"
	ParentDir => "a .. part"
	DotPart => "a . part"
	ReservedName => "a Windows reserved name"
	EndsWithSpace => "a part ends with a space"
	EndsWithPeriod => "a part ends with a period"
	ReservedChar(c) => "the character ${byte_text(c)}"
	Backslash => "a backslash"
}

kind_text : Tar.Kind -> Str
kind_text = |kind| match kind {
	Symlink => "a symbolic link"
	HardLink => "a hard link"
	Other(c) => "a member of type ${byte_text(c)}"
	File => "a file"
	Dir => "a dir"
}

byte_text : U8 -> Str
byte_text = |c| Str.from_utf8([c]) ?? c.to_str()
