app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.2/5xpAVbae476YyEYkJSpkTAZFPeG43H5R7KM8u9j3rYKX.tar.zst" }
import pf.Worker
import pf.R2
import pf.Response
r : R2.Range
r = Suffix(5)
fetch! = |_req| Ok(Response.from_text(200, "x"))
worker = Worker.new({ fetch!: fetch! })
event! = |e| worker.event!(e)
