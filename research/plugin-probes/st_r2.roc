app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.R2
import pf.Kv

files = R2.binding("FILES")

fetch! : Request => Try(Response, _)
fetch! = |req| match (req.method, req.segments()) {
	(PUT, ["files", key]) => {
		meta = files.put!(key, req.body)?
		Ok(Response.from_text(201, meta.etag))
	}
	(GET, ["files", key]) => {
		obj = files.get!(key)?
		Ok(Response.from_body(200, obj.meta.http.?content_type ?? "application/octet-stream", obj.body))
	}
	(GET, ["head", key]) => {
		meta = files.head!(key)?
		Ok(Response.from_text(200, meta.size_bytes.to_str()))
	}
	(GET, ["range", key]) => {
		obj = files.get_with!(key, { range: From({ offset_bytes: 0, length_bytes: 100 }) })?
		Ok(Response.from_body(206, "application/octet-stream", obj.body))
	}
	(PUT, ["cas", key]) => {
		etag = req.header("If-Match")?
		res = files.put_with!(key, req.body, { only_if: { etag_matches: etag } })
		match res {
			Ok(meta) => Ok(Response.from_text(200, meta.etag))
			Err(PreconditionFailed) => Ok(Response.from_status(412))
			Err(e) => Err(e)
		}
	}
	(GET, ["list"]) => {
		page = files.list!({ prefix: "a/", limit: 100 })?
		names = page.objects.map(|o| o.key)
		Ok(Response.from_json(200, names))
	}
	(POST, ["mp", key]) => {
		up = files.create_multipart_upload!(key)?
		Ok(Response.from_json(200, { upload_id: up.upload_id }))
	}
	(PUT, ["mp", key, upload_id, n]) => {
		up = files.resume_multipart_upload(key, upload_id)
		num = U32.from_str(n)?
		part = up.upload_part!(num, req.body)?
		Ok(Response.from_json(200, part))
	}
	(DELETE, ["files", key]) => {
		files.delete!([key])?
		Ok(Response.from_status(204))
	}
	_ => Ok(Response.from_status(404))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
