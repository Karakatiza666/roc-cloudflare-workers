app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Kv

kv : Kv(Str)
kv = Kv.json("X")

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	kv.put_with!("a", "b", { metadata: { owner: "me" } })?
	Ok(Response.from_text(200, "ok"))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
