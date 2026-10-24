app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Kv

notes = Kv.text("NOTES")

Tag : { owner : Str }

owners! : {} => Try(List(Str), _)
owners! = |{}| {
	page = notes.list!({ prefix: "n/" })?
	page.keys.map_try(|key| {
		tag : Tag
		tag = (key.metadata ? |_| Missing).parse()?
		Ok(tag.owner)
	})
}
fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_json(200, owners!({})?))

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
