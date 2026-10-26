app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Time
import pf.Log
import pf.D1
import pf.Http
import pf.Io
import pf.Ctx
import pf.Body
import pf.Env
import pf.WebCrypto
import pf.Memo

fetch! : Request => Try(Response, [])
fetch! = |_req| Ok(Response.from_status(404))

scheduled! : Worker.Scheduled => Try({}, [UnknownCron(Str)])
scheduled! = |s| Err(UnknownCron(s.cron()))

worker = Worker.new({ fetch!: fetch!, scheduled!: scheduled! })

event! = |e| worker.event!(e)
