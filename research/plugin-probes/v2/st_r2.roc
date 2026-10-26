app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.R2
import pf.Body
import pf.Io

files = R2.binding("FILES")

upload! : Str, Request => Try(Response, _)
upload! = |key, req| {
	meta = files.put_with!(key, req.body(), { http: { content_type: req.header("content-type") ?? "application/octet-stream" } })?
	Ok(Response.from_text(201, meta.etag))
}

download! : Str, Request => Try(Response, _)
download! = |key, req| Ok(files.respond!(key, req)?)

first_kib! : Str => Try(Response, _)
first_kib! = |key| match files.get_with!(key, { range: From({ offset_bytes: 0, length_bytes: 1024 }) }) {
	Ok(obj) => {
		range = match obj.?range {
			Ok(From(r)) => "bytes ${r.offset_bytes.to_str()}-${(r.offset_bytes + (r.?length_bytes ?? 0) - 1).to_str()}/${obj.meta.size_bytes.to_str()}"
			_ => "bytes */${obj.meta.size_bytes.to_str()}"
		}
		Ok(R2.to_response(obj).with_header("content-range", range))
	}
	Err(NotFound) => Ok(Response.from_status(404))
	Err(e) => Err(e)
}

replace! : Str, Request => Try(Response, _)
replace! = |key, req| match files.put_with!(key, req.body(), { only_if: R2.from_headers(req.headers()) }) {
	Ok(meta) => Ok(Response.from_text(200, meta.etag))
	Err(PreconditionFailed) => Ok(Response.from_status(412))
	Err(e) => Err(e)
}

create_only! : Str => Try(Response, _)
create_only! = |key| match files.put_with!(key, Text("{}"), { only_if: R2.absent }) {
	Ok(_) => Ok(Response.from_status(201))
	Err(PreconditionFailed) => Ok(Response.from_status(409))
	Err(e) => Err(e)
}

generated! : Str => Try(Response, _)
generated! = |key| {
	{ body, writer } = Body.writer!()?
	_ = Io.start!(writer.write_text("hello, "))
	_ = Io.start!(writer.write_text("world"))
	writer.close!()
	_ = files.put!(key, body)?
	Ok(Response.from_status(201))
}

list! : Str, Str => Try(Response, _)
list! = |prefix, cursor| {
	page = if cursor == "" {
		files.list!({ prefix, delimiter: "/", include: [Http] })?
	} else {
		files.list!({ prefix, delimiter: "/", include: [Http], cursor })?
	}
	next = match page.next {
		More(c) => c
		Done => ""
	}
	Ok(Response.from_json(200, { keys: page.objects.map(|o| o.key), folders: page.prefixes, next }))
}

mp_start! : Str => Try(Response, _)
mp_start! = |key| {
	up = files.create_multipart_upload_with!(key, { http: { content_type: "application/zip" } })?
	Ok(Response.from_json(200, up))
}

mp_part! : Str, Str, Str, Request => Try(Response, _)
mp_part! = |key, upload_id, n, req| {
	part_number = U32.from_str(n) ? |_| Infra(BadData("part number"))
	part = files.resume_multipart_upload(key, upload_id).upload_part!(part_number, req.body())?
	Ok(Response.from_json(200, part))
}

mp_done! : Str, Str, Request => Try(Response, _)
mp_done! = |key, upload_id, req| {
	parts : List(R2.Part)
	parts = req.json!()?
	_ = files.resume_multipart_upload(key, upload_id).complete!(parts)?
	meta = files.head!(key)?
	Ok(Response.from_text(200, meta.http.?content_type ?? "none"))
}

remove! : Str => Try(Response, _)
remove! = |key| {
	files.delete!([key])?
	Ok(Response.from_status(204))
}

fetch! : Request => Try(Response, _)
fetch! = |req| match (req.method(), req.segments()) {
	(PUT, ["files", key]) => upload!(key, req)
	(GET, ["files", key]) => download!(key, req)
	(GET, ["head", key]) => first_kib!(key)
	(POST, ["replace", key]) => replace!(key, req)
	(POST, ["create", key]) => create_only!(key)
	(POST, ["generated", key]) => generated!(key)
	(GET, ["list"]) => list!(req.query("prefix") ?? "", req.query("cursor") ?? "")
	(POST, ["mp", key]) => mp_start!(key)
	(PUT, ["mp", key, upload_id, n]) => mp_part!(key, upload_id, n, req)
	(POST, ["mp", key, upload_id]) => mp_done!(key, upload_id, req)
	(DELETE, ["files", key]) => remove!(key)
	_ => Ok(Response.from_status(404))
}

worker = Worker.new({ fetch!: fetch!, bindings: [files.declare()] })

event! = |e| worker.event!(e)
