## An R2 bucket (MODULES.md 5.3): `env[name]`, one program for each call. A body is a `Body` (a stream stays in JS, API.md
## RS3), so an object goes to a response with no copy into wasm (10a). A missing object is `NotFound` (OP7: `Fields` of
## the `null` result). A throw is `R2Err`. `R2.respond!` and `R2.to_response` make the HTTP response of an object
## (`Response` cannot import `R2`, so they are here: MODULES.md 4). The reads that the platform does as a `Js` tree have no `BadData`: a shape
## that is not the shape of the program is a platform bug, a crash.
import Io
import Js
import Body
import Request
import Response
import http.Header

R2 :: { name : Str }.{
	binding : Str -> R2
	binding = |name| R2.{ name }

	## The object and its body (a stream). `get` of a key that is not there: `NotFound`.
	get : R2, Str -> Io(R2.Object, [NotFound, R2Err(Io.Thrown)])
	get = |bucket, key| {
		ops = read_ops(call_ops(bucket, "get", [Lit(Text(key))], []))
		Io.new(
			ops,
			|r| match r {
				Ok(v) => match unpack(v) {
					Err(Missing) => Err(NotFound)
					Ok(got) => match object_of(got, Bool.False) {
						Ok(obj) => Ok(obj)
						Err(NoBody) => crash "R2.get: the object has no body"
					}
				}
				Err(t) => Err(R2Err(t))
			},
		)
	}

	get! : R2, Str => Try(R2.Object, [NotFound, R2Err(Io.Thrown)])
	get! = |bucket, key| Io.run!(get(bucket, key))

	## `range`: the bytes to read. `only_if`: a failed condition is `PreconditionFailed` (R2 gives the object with no body).
	get_with : R2, Str, { range ?: R2.Range, only_if ?: R2.Cond } -> Io(R2.Object, [NotFound, PreconditionFailed, R2Err(Io.Thrown)])
	get_with = |bucket, key, opts| {
		given = get_program(bucket, key, opts)
		Io.new(
			given.ops,
			|r| match fetched_of(r, given.with_range) {
				Ok(Found(obj)) => Ok(obj)
				Ok(NotMet(_)) => Err(PreconditionFailed)
				Ok(Absent) => Err(NotFound)
				Err(e) => Err(e)
			},
		)
	}

	get_with! : R2, Str, { range ?: R2.Range, only_if ?: R2.Cond } => Try(R2.Object, [NotFound, PreconditionFailed, R2Err(Io.Thrown)])
	get_with! = |bucket, key, opts| Io.run!(get_with(bucket, key, opts))

	## The HTTP response of an object: status 200, the body (a stream, no copy into wasm), the HTTP metadata of the object
	## (`content-type`, `content-language`, `content-disposition`, `content-encoding`, `cache-control`, `expires`) and
	## `etag` (`http_etag`). The same headers as `writeHttpMetadata` and `httpEtag` of Workers.
	to_response : R2.Object -> Response
	to_response = |obj| Response.{ status: 200, headers: meta_headers(obj.meta), body: obj.body }

	## A GET request answered from the bucket. The key is the argument, the request gives the conditions and the range.
	## `If-None-Match` and `If-Modified-Since` that fail: 304 with `etag`. `If-Match` and `If-Unmodified-Since` that
	## fail: 412. A key that is not there: 404. A `Range` of one range (`bytes=a-b`, `bytes=a-`, `bytes=-n`): 206 with
	## `content-range`, 416 when it starts after the end (R2 error 10039). A request with `If-Range` gets the whole object (R2 has no
	## `If-Range`). A `Range` that has more than one range, or has a wrong form, is not used. The method is not read:
	## the app routes GET and HEAD to it. The bytes of a HEAD response are dropped by Workers.
	respond : R2, Str, Request -> Io(Response, [R2Err(Io.Thrown)])
	respond = |bucket, key, req| {
		wanted = wanted_range(req)
		opts0 : { range ?: R2.Range, only_if ?: R2.Cond }
		opts0 = { only_if: R2.from_headers(req.headers) }
		opts = match wanted {
			Ok(range) => { ..opts0, range }
			Err(_) => opts0
		}
		given = get_program(bucket, key, opts)
		Io.new(
			given.ops,
			|r| match fetched_of(r, given.with_range) {
				Ok(Found(obj)) => Ok(found_response(obj, wanted))
				Ok(NotMet(meta)) => Ok(not_met_response(req, meta))
				Ok(Absent) => Ok(Response.from_text(404, "Not found"))
				# R2 error 10039: the range starts after the end.
				Err(R2Err(t)) => if t.message.contains("(10039)") Ok(Response.from_status(416)) else Err(R2Err(t))
			},
		)
	}

	respond! : R2, Str, Request => Try(Response, [R2Err(Io.Thrown)])
	respond! = |bucket, key, req| Io.run!(respond(bucket, key, req))

	## The metadata only (`head`).
	head : R2, Str -> Io(R2.Meta, [NotFound, R2Err(Io.Thrown)])
	head = |bucket, key| {
		ops = read_ops(call_ops(bucket, "head", [Lit(Text(key))], []))
		Io.new(
			ops,
			|r| match r {
				Ok(v) => match unpack(v) {
					Err(Missing) => Err(NotFound)
					Ok(got) => Ok(got.meta)
				}
				Err(t) => Err(R2Err(t))
			},
		)
	}

	head! : R2, Str => Try(R2.Meta, [NotFound, R2Err(Io.Thrown)])
	head! = |bucket, key| Io.run!(head(bucket, key))

	put : R2, Str, Body -> Io(R2.Meta, [R2Err(Io.Thrown)])
	put = |bucket, key, body| {
		given = body_ops(body, Err(MissingField), 1)
		ops = read_ops(call_ops(bucket, "put", [Lit(Text(key)), given.arg], given.ops))
		Io.new(
			ops,
			|r| match r {
				Ok(v) => match unpack(v) {
					Err(Missing) => crash "R2.put: R2 gave no object"
					Ok(got) => Ok(got.meta)
				}
				Err(t) => Err(R2Err(t))
			},
		)
	}

	put! : R2, Str, Body => Try(R2.Meta, [R2Err(Io.Thrown)])
	put! = |bucket, key, body| Io.run!(put(bucket, key, body))

	## `only_if` makes it a compare and swap: a failed condition is `PreconditionFailed` (R2 gives `null`).
	## `length_bytes`: a stream that the app makes (`Body.writer!`) has no known length, so it goes through a
	## `FixedLengthStream` of this length. A stream of another length is `R2Err`.
	put_with : R2, Str, Body, { only_if ?: R2.Cond, http ?: R2.Http, custom ?: List((Str, Str)), checksum ?: R2.Checksum, length_bytes ?: U64 } -> Io(R2.Meta, [PreconditionFailed, R2Err(Io.Thrown)])
	put_with = |bucket, key, body, opts| {
		given = body_ops(body, opts.?length_bytes, 1)
		built = put_options(opts, 1 + given.ops.len().to_u32_wrap())
		ops = read_ops(call_ops(bucket, "put", [Lit(Text(key)), given.arg, Slot(built.slot)], given.ops.concat(built.ops)))
		Io.new(
			ops,
			|r| match r {
				Ok(v) => match unpack(v) {
					Err(Missing) => Err(PreconditionFailed)
					Ok(got) => Ok(got.meta)
				}
				Err(t) => Err(R2Err(t))
			},
		)
	}

	put_with! : R2, Str, Body, { only_if ?: R2.Cond, http ?: R2.Http, custom ?: List((Str, Str)), checksum ?: R2.Checksum, length_bytes ?: U64 } => Try(R2.Meta, [PreconditionFailed, R2Err(Io.Thrown)])
	put_with! = |bucket, key, body, opts| Io.run!(put_with(bucket, key, body, opts))

	## Up to 1,000 keys.
	delete : R2, List(Str) -> Io({}, [R2Err(Io.Thrown)])
	delete = |bucket, keys| Io.new(
		call_ops(bucket, "delete", [Lit(Arr(keys.map(|k| Text(k))))], []),
		|r| match r {
			Ok(_) => Ok({})
			Err(t) => Err(R2Err(t))
		},
	)

	delete! : R2, List(Str) => Try({}, [R2Err(Io.Thrown)])
	delete! = |bucket, keys| Io.run!(delete(bucket, keys))

	## 1,000 objects or less. `include` fills `http` and `custom` of each `Meta` (with no `include`, they are empty).
	## The platform helper `pf.r2list` reads each object in JS: a program has no loop (OP4).
	list : R2, { prefix ?: Str, cursor ?: Str, limit ?: U32, delimiter ?: Str, start_after ?: Str, include ?: List([Http, Custom]) } -> Io({ objects : List(R2.Meta), prefixes : List(Str), next : [More(Str), Done] }, [R2Err(Io.Thrown)])
	list = |bucket, opts| {
		given = [
			opts.?prefix.map_ok(|s| ("prefix", Text(s))),
			opts.?cursor.map_ok(|s| ("cursor", Text(s))),
			opts.?limit.map_ok(|n| ("limit", Int(n.to_i64()))),
			opts.?delimiter.map_ok(|s| ("delimiter", Text(s))),
			opts.?start_after.map_ok(|s| ("startAfter", Text(s))),
			opts.?include.map_ok(|inc| ("include", Arr(inc.map(|i| Text(include_name(i)))))),
		].keep_oks(|f| f)
		Io.new(
			[
				Get(Root("env"), bucket.name),
				Call(Slot(0), "list", [Lit(Obj(given))]),
				Call(Root("pf"), "r2list", [Slot(1)]),
			],
			|r| match r {
				Ok(v) => Ok(list_of(v))
				Err(t) => Err(R2Err(t))
			},
		)
	}

	list! : R2, { prefix ?: Str, cursor ?: Str, limit ?: U32, delimiter ?: Str, start_after ?: Str, include ?: List([Http, Custom]) } => Try({ objects : List(R2.Meta), prefixes : List(Str), next : [More(Str), Done] }, [R2Err(Io.Thrown)])
	list! = |bucket, opts| Io.run!(list(bucket, opts))

	create_multipart_upload : R2, Str -> Io(R2.Upload, [R2Err(Io.Thrown)])
	create_multipart_upload = |bucket, key| create_upload(bucket, key, [Lit(Text(key))], [])

	create_multipart_upload! : R2, Str => Try(R2.Upload, [R2Err(Io.Thrown)])
	create_multipart_upload! = |bucket, key| Io.run!(create_multipart_upload(bucket, key))

	create_multipart_upload_with : R2, Str, { http ?: R2.Http, custom ?: List((Str, Str)) } -> Io(R2.Upload, [R2Err(Io.Thrown)])
	create_multipart_upload_with = |bucket, key, opts| {
		built = upload_options(opts, 1)
		create_upload(bucket, key, [Lit(Text(key)), Slot(built.slot)], built.ops)
	}

	create_multipart_upload_with! : R2, Str, { http ?: R2.Http, custom ?: List((Str, Str)) } => Try(R2.Upload, [R2Err(Io.Thrown)])
	create_multipart_upload_with! = |bucket, key, opts| Io.run!(create_multipart_upload_with(bucket, key, opts))

	## No crossing: `resumeMultipartUpload` checks nothing (Cloudflare docs). A wrong upload id is `R2Err` at the first
	## `upload_part!`, `complete!` or `abort!`.
	resume_multipart_upload : R2, Str, Str -> R2.Upload
	resume_multipart_upload = |bucket, key, upload_id| R2.Upload.{ bucket: bucket.name, key, upload_id }

	## A multipart upload as data, so a later request can go on with it (MC1: no ref). Each function resumes the
	## upload in its own program (`resumeMultipartUpload`, sync).
	Upload := { bucket : Str, key : Str, upload_id : Str }.{
		parser_for : _
		encoder_for : _
		is_eq : _

		## Part numbers are 1 to 10,000. Each part but the last is 5 MiB or more, and all have one size.
		upload_part : R2.Upload, U32, Body -> Io(R2.Part, [R2Err(Io.Thrown)])
		upload_part = |up, number, body| part_io(up, number, body, Err(MissingField))

		upload_part! : R2.Upload, U32, Body => Try(R2.Part, [R2Err(Io.Thrown)])
		upload_part! = |up, number, body| Io.run!(upload_part(up, number, body))

		## `length_bytes`: as in `put_with`, for a stream that has no known length.
		upload_part_with : R2.Upload, U32, Body, { length_bytes ?: U64 } -> Io(R2.Part, [R2Err(Io.Thrown)])
		upload_part_with = |up, number, body, opts| part_io(up, number, body, opts.?length_bytes)

		upload_part_with! : R2.Upload, U32, Body, { length_bytes ?: U64 } => Try(R2.Part, [R2Err(Io.Thrown)])
		upload_part_with! = |up, number, body, opts| Io.run!(upload_part_with(up, number, body, opts))

		## On the edge the `R2.Meta` of the result has no `http` and no `custom` (Miniflare has them): read them with `head!`
		## (MODULES.md 5.3, PLAN.md 11c, E28).
		complete : R2.Upload, List(R2.Part) -> Io(R2.Meta, [R2Err(Io.Thrown)])
		complete = |up, parts| {
			parts_js = Arr(parts.map(|p| Obj([("partNumber", Int(p.part_number.to_i64())), ("etag", Text(p.etag))])))
			ops = read_ops(resume_ops(up).append(Call(Slot(1), "complete", [Lit(parts_js)])))
			Io.new(
				ops,
				|r| match r {
					Ok(v) => match unpack(v) {
						Err(Missing) => crash "R2.Upload.complete: R2 gave no object"
						Ok(got) => Ok(got.meta)
					}
					Err(t) => Err(R2Err(t))
				},
			)
		}

		complete! : R2.Upload, List(R2.Part) => Try(R2.Meta, [R2Err(Io.Thrown)])
		complete! = |up, parts| Io.run!(complete(up, parts))

		abort : R2.Upload -> Io({}, [R2Err(Io.Thrown)])
		abort = |up| Io.new(
			resume_ops(up).append(Call(Slot(1), "abort", [])),
			|r| match r {
				Ok(_) => Ok({})
				Err(t) => Err(R2Err(t))
			},
		)

		abort! : R2.Upload => Try({}, [R2Err(Io.Thrown)])
		abort! = |up| Io.run!(abort(up))
	}

	Part : { part_number : U32, etag : Str }

	## `range`: the bytes that R2 read, only for a call with a `range` option (the edge and Miniflare give a range
	## also for a read of the whole object).
	Object : { meta : R2.Meta, body : Body, range ?: R2.Range }

	Meta : { key : Str, version : Str, size_bytes : U64, etag : Str, http_etag : Str, uploaded_ms : U64, http : R2.Http, custom : List((Str, Str)), checksums : R2.Checksums }

	Http : { content_type ?: Str, content_language ?: Str, content_disposition ?: Str, content_encoding ?: Str, cache_control ?: Str, cache_expiry_ms ?: U64 }

	Checksums : { md5 ?: List(U8), sha1 ?: List(U8), sha256 ?: List(U8), sha384 ?: List(U8), sha512 ?: List(U8) }

	Checksum : [Md5(List(U8)), Sha1(List(U8)), Sha256(List(U8)), Sha384(List(U8)), Sha512(List(U8))]

	## `R2Conditional`: R2 checks each field that is there. `headers`: the conditional headers of a request
	## (If-Match, If-None-Match, If-Modified-Since, If-Unmodified-Since). R2 reads them as it reads the headers of a
	## request: a quoted etag is fine. A weak etag matches only in If-None-Match (If-Match uses strong comparison). The
	## other fields are not used when `headers` is there.
	Cond : { etag_matches ?: Str, etag_does_not_match ?: Str, uploaded_before_ms ?: U64, uploaded_after_ms ?: U64, headers ?: List(Header) }

	## `only_if: R2.from_headers(req.headers)`: the conditions of the request. A header that is not a conditional header
	## is not sent to R2.
	from_headers : List(Header) -> R2.Cond
	from_headers = |headers| { headers: headers }

	## Only a new key (`etagDoesNotMatch: "*"`).
	absent : R2.Cond
	absent = { etag_does_not_match: "*" }

	Range : [From({ offset_bytes : U64, length_bytes ?: U64 }), Suffix(U64)]
}

# ---- Programs ----

## What a get gave: the object, the metadata of an object whose condition failed (R2 gives no body), or no object.
Fetched : [Found(R2.Object), NotMet(R2.Meta), Absent]

## The program of `get` with options. `with_range`: the call had a `range`.
get_program : R2, Str, { range ?: R2.Range, only_if ?: R2.Cond } -> { ops : List(Js.Op), with_range : Bool }
get_program = |bucket, key, opts| {
	built = get_options(opts, 1)
	with_range = match opts.?range {
		Ok(_) => Bool.True
		Err(_) => Bool.False
	}
	{ ops: read_ops(call_ops(bucket, "get", [Lit(Text(key)), Slot(built.slot)], built.ops)), with_range }
}

fetched_of : Try(Js, Io.Thrown), Bool -> Try(Fetched, [R2Err(Io.Thrown)])
fetched_of = |r, with_range| match r {
	Ok(v) => match unpack(v) {
		Err(Missing) => Ok(Absent)
		Ok(got) => match object_of(got, with_range) {
			Ok(obj) => Ok(Found(obj))
			Err(NoBody) => Ok(NotMet(got.meta))
		}
	}
	Err(t) => Err(R2Err(t))
}

# ---- HTTP response ----

## The headers of the HTTP metadata of an object and its `etag`.
meta_headers : R2.Meta -> List(Header)
meta_headers = |meta| {
	h = meta.http
	[
		("content-type", h.?content_type),
		("content-language", h.?content_language),
		("content-disposition", h.?content_disposition),
		("content-encoding", h.?content_encoding),
		("cache-control", h.?cache_control),
		("expires", h.?cache_expiry_ms.map_ok(http_date)),
		("etag", Ok(meta.http_etag)),
	].keep_oks(|(name, v)| v.map_ok(|value| Header.{ name, value }))
}

## Only the headers that a 304 or a 412 response has.
validator_headers : R2.Meta -> List(Header)
validator_headers = |meta| meta_headers(meta).keep_if(|h| h.name == "etag" or h.name == "cache-control" or h.name == "expires")

## The range of the request, when R2 can read it: a `Range` with one range, and no `If-Range`.
wanted_range : Request -> Try(R2.Range, [NoRange])
wanted_range = |req| match (req.header("if-range"), req.header("range")) {
	(Err(_), Ok(text)) => parse_range(text)
	_ => Err(NoRange)
}

## `bytes=a-b`, `bytes=a-`, `bytes=-n`. A range that ends before it starts, and `bytes=-0`, are not used.
parse_range : Str -> Try(R2.Range, [NoRange])
parse_range = |text| {
	t = text.trim()
	if t.starts_with("bytes=") and !t.contains(",") {
		match t.drop_prefix("bytes=").split_first("-") {
			Ok({ before, after }) => match (U64.from_str(before.trim()), U64.from_str(after.trim())) {
				(Err(_), Ok(n)) => if n > 0 Ok(Suffix(n)) else Err(NoRange)
				(Ok(a), Err(_)) => if after.trim() == "" Ok(From({ offset_bytes: a })) else Err(NoRange)
				(Ok(a), Ok(b)) => if b >= a Ok(From({ offset_bytes: a, length_bytes: b - a + 1 })) else Err(NoRange)
				(Err(_), Err(_)) => Err(NoRange)
			}
			Err(_) => Err(NoRange)
		}
	} else {
		Err(NoRange)
	}
}

## The first and the last byte that a range reads, in an object of `size` bytes. `Err(Unsatisfiable)`: it starts at or
## after the end.
range_span : R2.Range, U64 -> Try({ first : U64, last : U64 }, [Unsatisfiable])
range_span = |range, size| match range {
	From(r) => if r.offset_bytes >= size {
		Err(Unsatisfiable)
	} else {
		last = match r.?length_bytes {
			Ok(len) => U64.min(r.offset_bytes + len - 1, size - 1)
			Err(_) => size - 1
		}
		Ok({ first: r.offset_bytes, last })
	}
	Suffix(n) => if size == 0 Err(Unsatisfiable) else Ok({ first: size - U64.min(n, size), last: size - 1 })
}

found_response : R2.Object, Try(R2.Range, [NoRange]) -> Response
found_response = |obj, wanted| {
	plain = { ..R2.to_response(obj), headers: meta_headers(obj.meta).append(Header.{ name: "accept-ranges", value: "bytes" }) }
	size = obj.meta.size_bytes
	match wanted {
		Ok(range) => match range_span(range, size) {
			Ok({ first, last }) => { ..plain, status: 206, headers: plain.headers.append(Header.{ name: "content-range", value: "bytes ${first.to_str()}-${last.to_str()}/${size.to_str()}" }) }
			Err(Unsatisfiable) => Response.{ status: 416, headers: [Header.{ name: "content-range", value: "bytes */${size.to_str()}" }] }
		}
		Err(_) => plain
	}
}

## 304 when the request asks "has it changed" (`If-None-Match`, `If-Modified-Since`), else 412.
not_met_response : Request, R2.Meta -> Response
not_met_response = |req, meta| {
	asks_change = req.header("if-none-match").is_ok() or req.header("if-modified-since").is_ok()
	Response.{ status: if asks_change 304 else 412, headers: validator_headers(meta) }
}

## "Sun, 06 Nov 1994 08:49:37 GMT" for a time in ms.
http_date : U64 -> Str
http_date = |ms| {
	secs = ms // 1000
	days = secs // 86400
	rest = secs % 86400
	# Days since 1970-01-01 to a civil date (H. Hinnant). Day 0 is a Thursday.
	z = days + 719468
	era = z // 146097
	doe = z - era * 146097
	yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	mp = (5 * doy + 2) // 153
	day = doy - (153 * mp + 2) // 5 + 1
	month = if mp < 10 mp + 3 else mp - 9
	year = yoe + era * 400 + (if month <= 2 1 else 0)
	weekday = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"].get((days % 7).to_u64()) ?? "Thu"
	month_name = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].get(month - 1) ?? "Jan"
	"${weekday}, ${two(day)} ${month_name} ${year.to_str()} ${two(rest // 3600)}:${two(rest % 3600 // 60)}:${two(rest % 60)} GMT"
}

two : U64 -> Str
two = |n| if n < 10 "0${n.to_str()}" else n.to_str()

## Slot 0: the binding. The ops of `before` (the pieces of the arguments) come next, then the call on slot 0.
call_ops : R2, Str, List(Js.Arg), List(Js.Op) -> List(Js.Op)
call_ops = |bucket, method, args, before|
	[Get(Root("env"), bucket.name)].concat(before).append(Call(Slot(0), method, args))

## The ops after a call that gives an R2 object or `null`: the fields of the object (`Fields` of `null` is `undefined`,
## OP7), the fields of its checksums, and one record `{ meta, checksums }` (the last slot). `null` gives `meta: undefined`.
read_ops : List(Js.Op) -> List(Js.Op)
read_ops = |ops| {
	n = ops.len().to_u32_wrap()
	ops.concat([
		Fields(Slot(n - 1), ["key", "version", "size", "etag", "httpEtag", "uploaded", "httpMetadata", "customMetadata", "range", "body"]),
		Get(Slot(n - 1), "checksums"),
		Fields(Slot(n + 1), ["md5", "sha1", "sha256", "sha384", "sha512"]),
		Record([("meta", Slot(n)), ("checksums", Slot(n + 2))]),
	])
}

## `resumeMultipartUpload` of the upload: slot 0 the binding, slot 1 the `R2MultipartUpload`.
resume_ops : R2.Upload -> List(Js.Op)
resume_ops = |up| [
	Get(Root("env"), up.bucket),
	Call(Slot(0), "resumeMultipartUpload", [Lit(Text(up.key)), Lit(Text(up.upload_id))]),
]

create_upload : R2, Str, List(Js.Arg), List(Js.Op) -> Io(R2.Upload, [R2Err(Io.Thrown)])
create_upload = |bucket, key, args, before| {
	n = before.len().to_u32_wrap() + 2
	Io.new(
		call_ops(bucket, "createMultipartUpload", args, before).append(Fields(Slot(n - 1), ["uploadId"])),
		|r| match r {
			Ok(Obj(fields)) => match field(fields, "uploadId") {
				Text(id) => Ok(R2.Upload.{ bucket: bucket.name, key, upload_id: id })
				other => crash "R2.create_multipart_upload: the upload id is ${Str.inspect(other)}"
			}
			Ok(other) => crash "R2.create_multipart_upload: the upload is ${Str.inspect(other)}"
			Err(t) => Err(R2Err(t))
		},
	)
}

part_io : R2.Upload, U32, Body, Try(U64, [MissingField]) -> Io(R2.Part, [R2Err(Io.Thrown)])
part_io = |up, number, body, length| {
	before = resume_ops(up)
	given = body_ops(body, length, before.len().to_u32_wrap())
	n = before.len().to_u32_wrap() + given.ops.len().to_u32_wrap()
	Io.new(
		before.concat(given.ops).concat([Call(Slot(1), "uploadPart", [Lit(Int(number.to_i64())), given.arg]), Fields(Slot(n), ["partNumber", "etag"])]),
		|r| match r {
			Ok(Obj(fields)) => match (field(fields, "partNumber"), field(fields, "etag")) {
				(Int(p), Text(e)) => Ok({ part_number: p.to_u32_try() ?? crash "R2.Upload.upload_part: part number ${p.to_str()}", etag: e })
				other => crash "R2.Upload.upload_part: the part is ${Str.inspect(other)}"
			}
			Ok(other) => crash "R2.Upload.upload_part: the part is ${Str.inspect(other)}"
			Err(t) => Err(R2Err(t))
		},
	)
}

## The body as an argument. A stream with a `length_bytes` goes through a `FixedLengthStream` first (R2 takes a stream only
## with a known length). `base`: the number of ops before these. Gives the ops and the argument.
body_ops : Body, Try(U64, [MissingField]), U32 -> { ops : List(Js.Op), arg : Js.Arg }
body_ops = |body, length, base| match body {
	Empty => { ops: [], arg: Lit(Null) }
	Text(s) => { ops: [], arg: Lit(Text(s)) }
	Bytes(b) => { ops: [], arg: Lit(Bytes(b)) }
	Stream(r) => match length {
		Ok(n) => {
			ops: [
				New(Root("global"), "FixedLengthStream", [Lit(Int(int(n)))]),
				Call(Ref(r), "pipeThrough", [Slot(base)]),
			],
			arg: Slot(base + 1),
		}
		Err(_) => { ops: [], arg: Lit(Ref(r)) }
	}
}

# ---- Options ----

## The ops that make a JS object. `base`: the number of ops of the program before these. `fields`: the argument of each
## field. A time is a `Date`, made by a `New` op first.
Build : { base : U32, ops : List(Js.Op), fields : List((Str, Js.Arg)) }

build : U32 -> Build
build = |base| { base, ops: [], fields: [] }

## The slot of the next op of the build.
next : Build -> U32
next = |b| b.base + b.ops.len().to_u32_wrap()

put_text : Build, Str, Try(Str, [MissingField]) -> Build
put_text = |b, name, t| match t {
	Ok(s) => { ..b, fields: b.fields.append((name, Lit(Text(s)))) }
	Err(_) => b
}

put_date : Build, Str, Try(U64, [MissingField]) -> Build
put_date = |b, name, t| match t {
	Ok(ms) => {
		slot = next(b)
		{ ..b, ops: b.ops.append(New(Root("global"), "Date", [Lit(Int(int(ms)))])), fields: b.fields.append((name, Slot(slot))) }
	}
	Err(_) => b
}

put_lit : Build, Str, Js -> Build
put_lit = |b, name, v| { ..b, fields: b.fields.append((name, Lit(v))) }

## A field that is an object of its own build (`finish` of it).
put_record : Build, Str, { ops : List(Js.Op), slot : U32 } -> Build
put_record = |b, name, r| { ..b, ops: b.ops.concat(r.ops), fields: b.fields.append((name, Slot(r.slot))) }

## Appends the `Record` op. Gives the ops and the slot of the record.
finish : Build -> { ops : List(Js.Op), slot : U32 }
finish = |b| { ops: b.ops.append(Record(b.fields)), slot: next(b) }

int : U64 -> I64
int = |n| n.to_i64_try() ?? I64.highest

## The `onlyIf` argument: a `Headers` for `headers`, else a record of the fields. Gives the ops and the slot.
cond_ops : R2.Cond, U32 -> { ops : List(Js.Op), slot : U32 }
cond_ops = |c, base| match c.?headers {
	Ok(headers) => { ops: [New(Root("global"), "Headers", [Lit(Obj(conditional_headers(headers)))])], slot: base }
	Err(_) => finish(cond_build(c, base))
}

## The conditional headers of a request, each once, with a lower case name (a `Headers` has one value for each name here).
conditional_headers : List(Header) -> List((Str, Js))
conditional_headers = |headers| {
	names = ["if-match", "if-none-match", "if-modified-since", "if-unmodified-since"]
	names.keep_oks(
		|name| match headers.find_first(|h| h.name.with_ascii_lowercased() == name) {
			Ok(h) => Ok((name, Text(h.value)))
			Err(_) => Err(NotThere)
		},
	)
}

cond_build : R2.Cond, U32 -> Build
cond_build = |c, base|
	build(base)
		|> put_text("etagMatches", c.?etag_matches)
		|> put_text("etagDoesNotMatch", c.?etag_does_not_match)
		|> put_date("uploadedBefore", c.?uploaded_before_ms)
		|> put_date("uploadedAfter", c.?uploaded_after_ms)

http_build : R2.Http, U32 -> Build
http_build = |h, base|
	build(base)
		|> put_text("contentType", h.?content_type)
		|> put_text("contentLanguage", h.?content_language)
		|> put_text("contentDisposition", h.?content_disposition)
		|> put_text("contentEncoding", h.?content_encoding)
		|> put_text("cacheControl", h.?cache_control)
		|> put_date("cacheExpiry", h.?cache_expiry_ms)

custom_js : List((Str, Str)) -> Js
custom_js = |pairs| Obj(pairs.map(|(k, v)| (k, Text(v))))

include_name : [Http, Custom] -> Str
include_name = |i| match i {
	Http => "httpMetadata"
	Custom => "customMetadata"
}

## The options of `get`: `{ range, onlyIf }`.
get_options : { range ?: R2.Range, only_if ?: R2.Cond }, U32 -> { ops : List(Js.Op), slot : U32 }
get_options = |opts, base| {
	with_range = match opts.?range {
		Ok(From(r)) => {
			from = [("offset", Int(int(r.offset_bytes)))]
			put_lit(
				build(base),
				"range",
				Obj(
					match r.?length_bytes {
						Ok(len) => from.append(("length", Int(int(len))))
						Err(_) => from
					},
				),
			)
		}
		Ok(Suffix(n)) => put_lit(build(base), "range", Obj([("suffix", Int(int(n)))]))
		Err(_) => build(base)
	}
	finish(
		match opts.?only_if {
			Ok(c) => put_record(with_range, "onlyIf", cond_ops(c, next(with_range)))
			Err(_) => with_range
		},
	)
}

## The options of `put`: `{ onlyIf, httpMetadata, customMetadata, <hash> }`.
put_options : { only_if ?: R2.Cond, http ?: R2.Http, custom ?: List((Str, Str)), checksum ?: R2.Checksum, length_bytes ?: U64 }, U32 -> { ops : List(Js.Op), slot : U32 }
put_options = |opts, base| {
	b1 = match opts.?only_if {
		Ok(c) => put_record(build(base), "onlyIf", cond_ops(c, base))
		Err(_) => build(base)
	}
	b2 = match opts.?http {
		Ok(h) => put_record(b1, "httpMetadata", finish(http_build(h, next(b1))))
		Err(_) => b1
	}
	b3 = match opts.?custom {
		Ok(pairs) => put_lit(b2, "customMetadata", custom_js(pairs))
		Err(_) => b2
	}
	finish(
		match opts.?checksum {
			Ok(Md5(b)) => put_lit(b3, "md5", Bytes(b))
			Ok(Sha1(b)) => put_lit(b3, "sha1", Bytes(b))
			Ok(Sha256(b)) => put_lit(b3, "sha256", Bytes(b))
			Ok(Sha384(b)) => put_lit(b3, "sha384", Bytes(b))
			Ok(Sha512(b)) => put_lit(b3, "sha512", Bytes(b))
			Err(_) => b3
		},
	)
}

## The options of `createMultipartUpload`: `{ httpMetadata, customMetadata }`.
upload_options : { http ?: R2.Http, custom ?: List((Str, Str)) }, U32 -> { ops : List(Js.Op), slot : U32 }
upload_options = |opts, base| {
	b1 = match opts.?http {
		Ok(h) => put_record(build(base), "httpMetadata", finish(http_build(h, base)))
		Err(_) => build(base)
	}
	finish(
		match opts.?custom {
			Ok(pairs) => put_lit(b1, "customMetadata", custom_js(pairs))
			Err(_) => b1
		},
	)
}

# ---- Results ----

Got : { meta : R2.Meta, fields : List((Str, Js)) }

## The record of `read_ops`. `Err(Missing)`: no object (the result of the call was `null`).
unpack : Js -> Try(Got, [Missing])
unpack = |v| match v {
	Obj(top) => match (field(top, "meta"), field(top, "checksums")) {
		(Obj(fields), cs) => Ok({ meta: meta_of(fields, cs), fields })
		(Undefined, _) | (Null, _) => Err(Missing)
		(other, _) => crash "R2: the object is ${Str.inspect(other)}"
	}
	other => crash "R2: the result is ${Str.inspect(other)}"
}

## The object with its body. `with_range`: the call had a `range`, so the object has the range that R2 read.
## `Err(NoBody)`: the object has no body (R2 gives that for a failed condition of `get`).
object_of : Got, Bool -> Try(R2.Object, [NoBody])
object_of = |got, with_range| match field(got.fields, "body") {
	Ref(r) => {
		obj : R2.Object
		obj = { meta: got.meta, body: Stream(r) }
		if with_range {
			match range_of(field(got.fields, "range")) {
				Ok(range) => Ok({ ..obj, range })
				Err(NoRange) => Ok(obj)
			}
		} else {
			Ok(obj)
		}
	}
	_ => Err(NoBody)
}

range_of : Js -> Try(R2.Range, [NoRange])
range_of = |v| match v {
	Obj(f) => match (field(f, "offset"), field(f, "length"), field(f, "suffix")) {
		(_, _, Int(n)) => Ok(Suffix(to_u64(Int(n), "range suffix")))
		(Int(o), Int(l), _) => Ok(From({ offset_bytes: to_u64(Int(o), "range offset"), length_bytes: to_u64(Int(l), "range length") }))
		(Int(o), _, _) => Ok(From({ offset_bytes: to_u64(Int(o), "range offset") }))
		_ => Err(NoRange)
	}
	_ => Err(NoRange)
}

list_of : Js -> { objects : List(R2.Meta), prefixes : List(Str), next : [More(Str), Done] }
list_of = |v| match v {
	Obj(top) => {
		objects = match field(top, "objects") {
			Arr(items) => items.map(
				|item| match item {
					Obj(pair) => match field(pair, "meta") {
						Obj(fields) => meta_of(fields, field(pair, "checksums"))
						other => crash "R2.list: an object is ${Str.inspect(other)}"
					}
					other => crash "R2.list: an object is ${Str.inspect(other)}"
				},
			)
			other => crash "R2.list: the objects are ${Str.inspect(other)}"
		}
		prefixes = match field(top, "prefixes") {
			Arr(items) => items.map(|p| text_of(p, "a prefix"))
			other => crash "R2.list: the prefixes are ${Str.inspect(other)}"
		}
		more = match (field(top, "truncated"), field(top, "cursor")) {
			(Bool(Bool.True), Text(c)) => More(c)
			_ => Done
		}
		{ objects, prefixes, next: more }
	}
	other => crash "R2.list: the result is ${Str.inspect(other)}"
}

meta_of : List((Str, Js)), Js -> R2.Meta
meta_of = |f, checksums| {
	key: text_of(field(f, "key"), "key"),
	version: text_of(field(f, "version"), "version"),
	size_bytes: to_u64(field(f, "size"), "size"),
	etag: text_of(field(f, "etag"), "etag"),
	http_etag: text_of(field(f, "httpEtag"), "httpEtag"),
	uploaded_ms: to_u64(field(f, "uploaded"), "uploaded"),
	http: http_of(field(f, "httpMetadata")),
	custom: custom_of(field(f, "customMetadata")),
	checksums: checksums_of(checksums),
}

## Each field that the object has (`undefined` is absent). Record update sets an optional field.
http_of : Js -> R2.Http
http_of = |v| match v {
	Obj(f) => {
		h0 : R2.Http
		h0 = {}
		h1 = match field(f, "contentType") {
			Text(s) => { ..h0, content_type: s }
			_ => h0
		}
		h2 = match field(f, "contentLanguage") {
			Text(s) => { ..h1, content_language: s }
			_ => h1
		}
		h3 = match field(f, "contentDisposition") {
			Text(s) => { ..h2, content_disposition: s }
			_ => h2
		}
		h4 = match field(f, "contentEncoding") {
			Text(s) => { ..h3, content_encoding: s }
			_ => h3
		}
		h5 = match field(f, "cacheControl") {
			Text(s) => { ..h4, cache_control: s }
			_ => h4
		}
		match field(f, "cacheExpiry") {
			Undefined | Null => h5
			t => { ..h5, cache_expiry_ms: to_u64(t, "cacheExpiry") }
		}
	}
	_ => {}
}

custom_of : Js -> List((Str, Str))
custom_of = |v| match v {
	Obj(pairs) => pairs.map(|(k, x)| (k, text_of(x, "a custom value")))
	_ => []
}

checksums_of : Js -> R2.Checksums
checksums_of = |v| match v {
	Obj(f) => {
		c0 : R2.Checksums
		c0 = {}
		c1 = match field(f, "md5") {
			Bytes(b) => { ..c0, md5: b }
			_ => c0
		}
		c2 = match field(f, "sha1") {
			Bytes(b) => { ..c1, sha1: b }
			_ => c1
		}
		c3 = match field(f, "sha256") {
			Bytes(b) => { ..c2, sha256: b }
			_ => c2
		}
		c4 = match field(f, "sha384") {
			Bytes(b) => { ..c3, sha384: b }
			_ => c3
		}
		match field(f, "sha512") {
			Bytes(b) => { ..c4, sha512: b }
			_ => c4
		}
	}
	_ => {}
}

field : List((Str, Js)), Str -> Js
field = |fields, name| match fields.find_first(|(k, _)| k == name) {
	Ok((_, v)) => v
	Err(_) => Undefined
}

text_of : Js, Str -> Str
text_of = |v, what| match v {
	Text(s) => s
	other => crash "R2: ${what} is ${Str.inspect(other)}"
}

## A size or a time. A `Date` crosses as `Int` or `Num` (J4).
to_u64 : Js, Str -> U64
to_u64 = |v, what| match v {
	Int(i) => i.to_u64_try() ?? crash "R2: ${what} is ${i.to_str()}"
	Num(f) => f.to_u64_try() ?? crash "R2: ${what} is not a size or a time"
	other => crash "R2: ${what} is ${Str.inspect(other)}"
}

expect {
	# The two times of a condition are `Date`s, in the slots after the base.
	c : R2.Cond
	c = { etag_matches: "e", uploaded_before_ms: 5, uploaded_after_ms: 7 }
	built = finish(cond_build(c, 2))
	built.slot == 4 and Js.program(built.ops) == Js.program([
		New(Root("global"), "Date", [Lit(Int(5))]),
		New(Root("global"), "Date", [Lit(Int(7))]),
		Record([("etagMatches", Lit(Text("e"))), ("uploadedBefore", Slot(2)), ("uploadedAfter", Slot(3))]),
	])
}

expect {
	# An object with a range of 3 bytes from 2.
	got = unpack(
		Obj([
			(
				"meta",
				Obj([("key", Text("k")), ("version", Text("v")), ("size", Int(11)), ("etag", Text("e")), ("httpEtag", Text("\"e\"")), ("uploaded", Int(1000)), ("httpMetadata", Obj([("cacheControl", Text("max-age=60"))])), ("customMetadata", Obj([("a", Text("1"))])), ("range", Obj([("offset", Int(2)), ("length", Int(3))]))]),
			),
			("checksums", Obj([("md5", Bytes([1, 2])), ("sha1", Undefined)])),
		]),
	)
	match got {
		Ok(g) => g.meta.size_bytes == 11
			and g.meta.http.?cache_control == Ok("max-age=60")
				and g.meta.http.?content_type == Err(MissingField)
					and g.meta.custom == [("a", "1")]
						and g.meta.checksums.?md5 == Ok([1, 2])
							and g.meta.checksums.?sha1 == Err(MissingField)
								and range_of(field(g.fields, "range")) == Ok(From({ offset_bytes: 2, length_bytes: 3 }))
		Err(_) => Bool.False
	}
}

expect unpack(Obj([("meta", Undefined), ("checksums", Undefined)])) == Err(Missing)

expect http_date(784111777000) == "Sun, 06 Nov 1994 08:49:37 GMT"

expect http_date(1709164800000) == "Thu, 29 Feb 2024 00:00:00 GMT"

expect parse_range("bytes=2-4") == Ok(From({ offset_bytes: 2, length_bytes: 3 }))

expect parse_range("bytes=5-") == Ok(From({ offset_bytes: 5 }))

expect parse_range("bytes=-3") == Ok(Suffix(3))

expect parse_range("bytes=0-1,4-5") == Err(NoRange)

expect range_span(Suffix(100), 10) == Ok({ first: 0, last: 9 })

expect range_span(From({ offset_bytes: 10 }), 10) == Err(Unsatisfiable)
