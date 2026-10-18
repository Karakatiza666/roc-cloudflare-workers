## `R2` (MODULES.md 5.3, PLAN.md 8c). The binding `BUCKET` is in `checks/r2.mjs`. Each route answers `Ok <text>` or
## `Err <the error>`. `?key=` is the key. The twin of a route is `<name>_io`.
import pf.Request
import pf.Response
import pf.R2
import pf.Io
import pf.Body
import Q

bucket = R2.binding("BUCKET")

R2Routes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| {
		key = Q.text(req, "key")
		match path {
			["put"] => out(bucket.put!(key, Text(Q.text(req, "text"))), show_meta)
			["put_io"] => out(Io.run!(bucket.put(key, Text(Q.text(req, "text")))), show_meta)
			["get"] => out!(bucket.get!(key), show_object!)
			["get_io"] => out!(Io.run!(bucket.get(key)), show_object!)
			["head"] => out(bucket.head!(key), show_meta)
			["head_io"] => out(Io.run!(bucket.head(key)), show_meta)
			["put_with"] => out(bucket.put_with!(key, Text(Q.text(req, "text")), put_options(req)), show_meta)
			["put_with_io"] => out(Io.run!(bucket.put_with(key, Text(Q.text(req, "text")), put_options(req))), show_meta)
			["get_with"] => out!(bucket.get_with!(key, get_options(req)), show_object!)
			["get_with_io"] => out!(Io.run!(bucket.get_with(key, get_options(req))), show_object!)
			["get_cond"] => out!(bucket.get_with!(key, { only_if: R2.from_headers(req.headers) }), show_object!)
			["respond"] => respond!(bucket.respond!(key, req))
			["respond_io"] => respond!(Io.run!(bucket.respond(key, req)))
			["to_response"] => match bucket.get!(key) {
				Ok(obj) => R2.to_response(obj)
				Err(e) => Response.from_text(404, Str.inspect(e))
			}
			["delete"] => out(bucket.delete!(keys(req)), |_| "deleted")
			["delete_io"] => out(Io.run!(bucket.delete(keys(req))), |_| "deleted")
			["list"] => out(bucket.list!(list_options(req)), show_list)
			["list_io"] => out(Io.run!(bucket.list(list_options(req))), show_list)
			["put_stream"] => put_stream!(key, Q.text(req, "len"))
			["mp_create"] => mp_create!(key, part_number(req), Bool.False)
			["mp_create_io"] => mp_create!(key, part_number(req), Bool.True)
			["mp_resume"] => Response.from_text(200, Json.to_str(bucket.resume_multipart_upload(key, Q.text(req, "id"))))
			["mp_part"] => mp_part!(req, Bool.False)
			["mp_part_io"] => mp_part!(req, Bool.True)
			["mp_part_with"] => mp_part_with!(req, Bool.False)
			["mp_part_with_io"] => mp_part_with!(req, Bool.True)
			["mp_complete"] => mp_complete!(req, Bool.False)
			["mp_complete_io"] => mp_complete!(req, Bool.True)
			["mp_abort"] => mp_abort!(req, Bool.False)
			["mp_abort_io"] => mp_abort!(req, Bool.True)
			["mp_with"] => mp_with!(key, part_number(req), Q.text(req, "etag"), Bool.False)
			["mp_with_io"] => mp_with!(key, part_number(req), Q.text(req, "etag"), Bool.True)
			["big"] => big!(key)
			_ => Response.from_text(404, "no route")
		}
	}
}

# ---- Answers ----

## The response of `respond!` as it is, or a 500 for an R2 error.
respond! : Try(Response, [R2Err(Io.Thrown)]) => Response
respond! = |r| match r {
	Ok(resp) => resp
	Err(e) => Response.from_text(500, Str.inspect(e))
}

out : Try(a, e), (a -> Str) -> Response
out = |r, f| Response.from_text(
	200,
	match r {
		Ok(v) => "Ok ${f(v)}"
		Err(e) => "Err ${Str.inspect(e)}"
	},
)

out! : Try(a, e), (a => Str) => Response
out! = |r, f| Response.from_text(
	200,
	match r {
		Ok(v) => "Ok ${f(v)}"
		Err(e) => "Err ${Str.inspect(e)}"
	},
)

show_meta : R2.Meta -> Str
show_meta = |m| {
	custom = Str.join_with(m.custom.map(|(k, v)| "${k}=${v}"), ",")
	"key=${m.key} size=${m.size_bytes.to_str()} etag=${m.etag} cc=${m.http.?cache_control ?? "none"} type=${m.http.?content_type ?? "none"} custom=${custom} md5=${bytes_len(m.checksums.?md5)} sha256=${hex(m.checksums.?sha256)}"
}

bytes_len : Try(List(U8), [MissingField]) -> Str
bytes_len = |t| match t {
	Ok(b) => b.len().to_str()
	Err(_) => "none"
}

hex : Try(List(U8), [MissingField]) -> Str
hex = |t| match t {
	Ok(b) => match Crypto.SHA256.Digest.from_bytes(b) {
		Ok(d) => d.to_hex()
		Err(_) => "bytes${b.len().to_str()}"
	}
	Err(_) => "none"
}

show_object! : R2.Object => Str
show_object! = |obj| {
	range = match obj.?range {
		Ok(From(r)) => "from ${r.offset_bytes.to_str()} len ${(r.?length_bytes ?? 0).to_str()}"
		Ok(Suffix(n)) => "suffix ${n.to_str()}"
		Err(_) => "none"
	}
	text = match obj.body.text!() {
		Ok(t) => t
		Err(e) => "body ${Str.inspect(e)}"
	}
	"size=${obj.meta.size_bytes.to_str()} range=${range} text=${text}"
}

show_list : { objects : List(R2.Meta), prefixes : List(Str), next : [More(Str), Done] } -> Str
show_list = |l| {
	objects = Str.join_with(l.objects.map(|m| "${m.key}:${m.http.?cache_control ?? "none"}:${Str.join_with(m.custom.map(|(k, v)| "${k}=${v}"), ",")}"), " ")
	next = match l.next {
		More(c) => if c == "" "More(empty)" else "More"
		Done => "Done"
	}
	"objects=[${objects}] prefixes=[${Str.join_with(l.prefixes, ",")}] next=${next}"
}

# ---- Options from the query ----

given : Request, Str -> Bool
given = |req, name| req.query(name).is_ok()

keys : Request -> List(Str)
keys = |req| Q.text(req, "keys").split_on(",")

## The condition: `etag`, `nomatch`, `before` and `after` (a time in ms).
cond : Request -> R2.Cond
cond = |req| {
	c0 : R2.Cond
	c0 = {}
	c1 = match req.query("etag") {
		Ok(e) => { ..c0, etag_matches: e }
		Err(_) => c0
	}
	c2 = match req.query("nomatch") {
		Ok(e) => { ..c1, etag_does_not_match: e }
		Err(_) => c1
	}
	c3 = match req.query("before") {
		Ok(_) => { ..c2, uploaded_before_ms: Q.num(req, "before") }
		Err(_) => c2
	}
	match req.query("after") {
		Ok(_) => { ..c3, uploaded_after_ms: Q.num(req, "after") }
		Err(_) => c3
	}
}

## `only_if` (`absent=1` or the fields of `cond`), `cc` (cache control), `custom` (`k:v`), `sha` (`right` or `wrong`: a
## SHA-256 of the text), `md5` (a wrong hash of 16 bytes).
put_options : Request -> { only_if ?: R2.Cond, http ?: R2.Http, custom ?: List((Str, Str)), checksum ?: R2.Checksum, length_bytes ?: U64 }
put_options = |req| {
	o0 : { only_if ?: R2.Cond, http ?: R2.Http, custom ?: List((Str, Str)), checksum ?: R2.Checksum, length_bytes ?: U64 }
	o0 = {}
	o1 = match req.query("absent") {
		Ok(_) => { ..o0, only_if: R2.absent }
		Err(_) => if given(req, "etag") or given(req, "nomatch") or given(req, "before") or given(req, "after") { ..o0, only_if: cond(req) } else o0
	}
	o2 = match req.query("cc") {
		Ok(cc) => { ..o1, http: { cache_control: cc } }
		Err(_) => o1
	}
	o3 = match req.query("custom") {
		Ok(kv) => match kv.split_first(":") {
			Ok({ before, after }) => { ..o2, custom: [(before, after)] }
			Err(_) => o2
		}
		Err(_) => o2
	}
	match req.query("sha") {
		Ok("right") => { ..o3, checksum: Sha256(Crypto.SHA256.hash(Q.text(req, "text").to_utf8()).to_bytes()) }
		Ok(_) => { ..o3, checksum: Sha256(List.repeat(0, 32)) }
		Err(_) => o3
	}
}

get_options : Request -> { range ?: R2.Range, only_if ?: R2.Cond }
get_options = |req| {
	o0 : { range ?: R2.Range, only_if ?: R2.Cond }
	o0 = {}
	o1 = match req.query("suffix") {
		Ok(_) => { ..o0, range: Suffix(Q.num(req, "suffix")) }
		Err(_) => match req.query("offset") {
			Ok(_) => match req.query("len") {
				Ok(_) => { ..o0, range: From({ offset_bytes: Q.num(req, "offset"), length_bytes: Q.num(req, "len") }) }
				Err(_) => { ..o0, range: From({ offset_bytes: Q.num(req, "offset") }) }
			}
			Err(_) => o0
		}
	}
	match req.query("etag") {
		Ok(_) => { ..o1, only_if: cond(req) }
		Err(_) => o1
	}
}

## `include=http`, `include=custom`, `include=both`.
list_options : Request -> { prefix ?: Str, cursor ?: Str, limit ?: U32, delimiter ?: Str, start_after ?: Str, include ?: List([Http, Custom]) }
list_options = |req| {
	o0 : { prefix ?: Str, cursor ?: Str, limit ?: U32, delimiter ?: Str, start_after ?: Str, include ?: List([Http, Custom]) }
	o0 = {}
	o1 = match req.query("prefix") {
		Ok(p) => { ..o0, prefix: p }
		Err(_) => o0
	}
	o2 = match req.query("start_after") {
		Ok(s) => { ..o1, start_after: s }
		Err(_) => o1
	}
	o3 = match req.query("limit") {
		Ok(_) => { ..o2, limit: Q.num(req, "limit").to_u32_wrap() }
		Err(_) => o2
	}
	o4 = match req.query("delimiter") {
		Ok(d) => { ..o3, delimiter: d }
		Err(_) => o3
	}
	o5 = match req.query("cursor") {
		Ok(c) => { ..o4, cursor: c }
		Err(_) => o4
	}
	match req.query("include") {
		Ok("http") => { ..o5, include: [Http] }
		Ok("custom") => { ..o5, include: [Custom] }
		Ok(_) => { ..o5, include: [Http, Custom] }
		Err(_) => o5
	}
}

# ---- A stream that the app makes ----

## A stream that the app makes: R2 needs a known length. With no `len`, the put of a `Body.writer!` stream fails at
## once. With `len`, `length_bytes` pipes the stream through a `FixedLengthStream`. The writes and the close come
## before the put, with the public API: `Io.start!` of the `write` and `write_text` twins queues the chunks (a write
## waits until the put reads it), then `close!` queues the end, then `put_with!` reads all of it.
put_stream! : Str, Str => Response
put_stream! = |key, len| match Body.writer!({}) {
	Err(BodyErr(t)) => Response.from_text(200, "writer ${t.name}")
	Ok({ body, writer }) =>
		if len == "" {
			out(bucket.put_with!(key, body, {}), show_meta)
		} else {
			_ = Io.start!(writer.write("hello ".to_utf8()))
			_ = Io.start!(writer.write_text("world"))
			writer.close!()
			out(bucket.put_with!(key, body, { length_bytes: U64.from_str(len) ?? 0 }), show_meta)
		}
}

# ---- Multipart ----

part_one : Body
part_one = Bytes(List.repeat(65, 5_242_880))

part_two : Body
part_two = Bytes(List.repeat(66, 1024))

## The part number of the first part (`part`, default 1). A number that R2 refuses makes the route abort the upload (PLAN.md EP10).
part_number : Request -> U32
part_number = |req| {
	n = Q.num(req, "part")
	if n == 0 1 else n.to_u32_wrap()
}

## Request 1: the upload and its part (5 MiB), as JSON.
mp_create! : Str, U32, Bool => Response
mp_create! = |key, number, twin| {
	made = if twin Io.run!(bucket.create_multipart_upload(key)) else bucket.create_multipart_upload!(key)
	match made {
		Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
		Ok(up) => {
			part = if twin Io.run!(up.upload_part(number, part_one)) else up.upload_part!(number, part_one)
			match part {
				Ok(p) => Response.from_text(200, "{\"upload\":${Json.to_str(up)},\"part\":${Json.to_str(p)}}")
				# PLAN.md EP10: the caller has no upload id on an error, so the upload is aborted here.
				Err(e) => {
					_aborted = up.abort!()
					Response.from_text(200, "Err ${Str.inspect(e)}")
				}
			}
		}
	}
}

upload_of : Request -> R2.Upload
upload_of = |req| match Json.parse(Q.text(req, "upload")) {
	Ok(up) => up
	Err(e) => crash "the upload is not JSON: ${Str.inspect(e)}"
}

## Request 2: part 2 (1 KB) on the upload of request 1.
mp_part! : Request, Bool => Response
mp_part! = |req, twin| {
	up : R2.Upload
	up = upload_of(req)
	part = if twin Io.run!(up.upload_part(2, part_two)) else up.upload_part!(2, part_two)
	match part {
		Ok(p) => Response.from_text(200, Json.to_str(p))
		Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
	}
}

## `upload_part_with`: part 2 from a stream that has no length, with `length_bytes` (`len`).
mp_part_with! : Request, Bool => Response
mp_part_with! = |req, twin| {
	up : R2.Upload
	up = upload_of(req)
	opts = { length_bytes: Q.num(req, "len") }
	part = if twin Io.run!(up.upload_part_with(2, part_two, opts)) else up.upload_part_with!(2, part_two, opts)
	match part {
		Ok(p) => Response.from_text(200, Json.to_str(p))
		Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
	}
}

## Request 3: `complete!` with both parts, then `get!`: the object body is the answer (a stream, no copy).
mp_complete! : Request, Bool => Response
mp_complete! = |req, twin| {
	up : R2.Upload
	up = upload_of(req)
	parts : List(R2.Part)
	parts = match Json.parse(Q.text(req, "parts")) {
		Ok(p) => p
		Err(e) => crash "the parts are not JSON: ${Str.inspect(e)}"
	}
	done = if twin Io.run!(up.complete(parts)) else up.complete!(parts)
	match done {
		Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
		Ok(_) => match bucket.get!(up.key) {
			Ok(obj) => Response.from_body(200, "application/octet-stream", obj.body)
			Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
		}
	}
}

mp_abort! : Request, Bool => Response
mp_abort! = |req, twin| {
	up : R2.Upload
	up = upload_of(req)
	done = if twin Io.run!(up.abort()) else up.abort!()
	out(done, |_| "aborted")
}

## `create_multipart_upload_with!`: the headers and the custom metadata of the object, then one part and `complete!`.
## `etag` (not empty) replaces the etag of the part, so that `complete!` fails (PLAN.md EP10).
mp_with! : Str, U32, Str, Bool => Response
mp_with! = |key, number, etag, twin| {
	opts : { http ?: R2.Http, custom ?: List((Str, Str)) }
	opts = { http: { cache_control: "max-age=30" }, custom: [("origin", "mp")] }
	made = if twin Io.run!(bucket.create_multipart_upload_with(key, opts)) else bucket.create_multipart_upload_with!(key, opts)
	match made {
		Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
		# PLAN.md EP10: an upload that does not complete is aborted here (the caller has no upload id).
		Ok(up) => match up.upload_part!(number, Text("last part")) {
			Err(e) => {
				_aborted = up.abort!()
				Response.from_text(200, "Err ${Str.inspect(e)}")
			}
			Ok(p) => {
				done = up.complete!([if etag == "" p else { ..p, etag }])
				if done.is_err() {
					_aborted = up.abort!()
				}
				out(done, show_meta)
			}
		}
	}
}

# ---- 10a ----

## An object to the response as a stream: no copy into wasm.
big! : Str => Response
big! = |key| match bucket.get!(key) {
	Ok(obj) => Response.from_body(200, "application/octet-stream", obj.body)
	Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
}
