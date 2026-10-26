app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Io
import pf.Ctx

slugify : Str -> Io(Str, [OpsErr(Io.Thrown)])
slugify = |s| Io.new([Call(Root("ops"), "slugify", [Lit(Text(s))])], |r| match r {
	Ok(Text(out)) => Ok(out)
	_ => Err(OpsErr({ name: "x", message: "y" }))
})

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	Ok(Response.from_status(200))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
