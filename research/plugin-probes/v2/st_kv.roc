app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Kv
import pf.Cache
import pf.Http

Prefs : { theme : Str, font_size : U32 }

prefs : Kv(Prefs)
prefs = Kv.json("PREFS")

site_default : Kv.Cell(Prefs)
site_default = prefs.cell("site-default")

notes : Kv(Str)
notes = Kv.text("NOTES")

Owner : { owner : Str }

read_prefs! : Str => Try(Prefs, _)
read_prefs! = |user| {
	fallback = site_default.get_or!({ theme: "light", font_size: 14 })?
	Ok(prefs.get_or!(user, fallback)?)
}

write_prefs! : Str, Request => Try({}, _)
write_prefs! = |user, req| {
	p : Prefs
	p = req.json!()?
	Ok(prefs.put_with!(user, p, { ttl_ms: 86_400_000, metadata: Kv.Metadata.of({ owner: user }) })?)
}

owner_of! : Str => Try(Str, _)
owner_of! = |user| {
	got = prefs.get_with_metadata!(user)?
	meta : Try(Owner, [Missing])
	meta = got.metadata
	Ok(
		match meta {
			Ok(m) => m.owner
			Err(Missing) => "nobody"
		},
	)
}

owners! : Str => Try(List(Str), _)
owners! = |prefix| {
	page = notes.list!({ prefix, limit: 100 })?
	page.keys.map_try(
		|key| {
			m : Owner
			m = key.metadata?.parse()?
			Ok(m.owner)
		},
	)
}

cached_proxy! : Request => Try(Response, _)
cached_proxy! = |req| {
	key = req.url()
	match Cache.default.get!(key) {
		Ok(hit) => Ok(hit)
		Err(NotFound) => {
			fresh = Http.get!("https://example.com/feed.json")?
			res = fresh.with_header("cache-control", "public, max-age=300")
			Ok(Cache.default.put_after!(key, res)?)
		}
		Err(e) => Err(e)
	}
}

purge! : Str => Try(Response, _)
purge! = |url| match Cache.named("feeds").delete!(url) {
	Ok({}) => Ok(Response.from_status(204))
	Err(NotFound) => Ok(Response.from_status(404))
	Err(e) => Err(e)
}

fetch! : Request => Try(Response, _)
fetch! = |req| match (req.method(), req.segments()) {
	(GET, ["prefs", user]) => {
		p = read_prefs!(user)?
		Ok(Response.from_json(200, p))
	}
	(PUT, ["prefs", user]) => {
		write_prefs!(user, req)?
		Ok(Response.from_status(204))
	}
	(GET, ["owner", user]) => {
		o = owner_of!(user)?
		Ok(Response.from_text(200, o))
	}
	(GET, ["owners"]) => {
		os = owners!(req.query("prefix") ?? "")?
		Ok(Response.from_json(200, os))
	}
	(GET, ["feed"]) => cached_proxy!(req)
	(DELETE, ["feed"]) => purge!(req.query("url") ?? "")
	_ => Ok(Response.from_status(404))
}

worker = Worker.new({ fetch!: fetch!, bindings: [prefs.declare(), notes.declare()] })

event! = |e| worker.event!(e)
