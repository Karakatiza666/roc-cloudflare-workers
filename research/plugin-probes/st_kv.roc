app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Kv
import pf.Cache
import pf.Ctx
import pf.Http

Prefs : { theme : Str, size : U32 }

prefs : Kv(Prefs)
prefs = Kv.json("PREFS")

notes = Kv.text("NOTES")

theme_cell = prefs.cell("default")

Tag : { owner : Str }

fetch! : Request => Try(Response, _)
fetch! = |req| match (req.method, req.segments()) {
	(GET, ["prefs", user]) => {
		p = prefs.get!(user) ?? { theme: "light", size: 12 }
		Ok(Response.from_json(200, p))
	}
	(PUT, ["prefs", user]) => {
		p : Prefs
		p = req.json!()?
		prefs.put_with!(user, p, { ttl_ms: 3_600_000, metadata: Kv.Metadata.of({ owner: user }) })?
		Ok(Response.from_status(204))
	}
	(GET, ["meta", user]) => {
		got = prefs.get_with_metadata!(user)?
		tag : Try(Tag, _)
		tag = got.metadata
		owner = match tag {
			Ok(t) => t.owner
			Err(_) => "none"
		}
		Ok(Response.from_text(200, owner))
	}
	(GET, ["notes"]) => {
		page = notes.list!({ prefix: "n/" })?
		Ok(Response.from_json(200, page.keys.map(|k| k.name)))
	}
	(GET, ["default"]) => {
		d = theme_cell.get!()?
		Ok(Response.from_text(200, d.theme))
	}
	(GET, ["proxy"]) => {
		key = req.url
		match Cache.default.get!(key) {
			Ok(hit) => Ok(hit)
			Err(NotFound) => {
				res = Http.get!("https://example.com/data")?
				Ctx.respond!(res)?
				Cache.default.put!(key, res)?
				Ok(res)
			}
			Err(e) => Err(e)
		}
	}
	_ => Ok(Response.from_status(404))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
