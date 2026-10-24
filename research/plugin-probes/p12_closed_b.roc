## The contract of a cloudflare-workers app: one `event!`, a `Worker` record of
## handlers, the one error type of all handlers, and the files of a project.
##
## A project has 4 files beside this app (the shim is not in the Roc index):
##
## | File | Content |
## | --- | --- |
## | app.roc | This file. Build: `roc build --target=wasm32 --no-cache --output=app.wasm app.roc` |
## | worker.js | `import app from './app.wasm'`, `import { makeHandler } from 'roc-cloudflare-workers'`, `export default makeHandler(app)` |
## | package.json | The shim, by the URL of the same release: `roc-cloudflare-workers-X.Y.Z.tgz`. It is not on the npm registry |
## | wrangler.toml | `main = "worker.js"`, `compatibility_flags = ["enable_request_signal"]`, one binding for each `X.binding("NAME")` |
##
## `--no-cache` is necessary: a warm build cache gave other code in the same build.
## Without `enable_request_signal`, a task does not stop when the client goes away.
app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Log

db = D1.binding("DB")

# The annotation is necessary here. With no annotation, `req.method` makes `req`
# a plain record, and then `req.segments()` is "missing method segments".
#
# Write `_` for the error type, not `[]`. All handlers of one `Worker` share
# one error type. `Try(Response, [])` closes it, and a second handler with an
# error then gives "invalid nominal record" at `Worker.{ ... }`.
fetch! : Request => Try(Response, _)
fetch! = |req| match (req.method, req.segments()) {
	(GET, []) => Ok(Response.from_text(200, "hello from Roc"))
	(GET, ["count"]) => Ok(count!({})?)
	(POST, ["echo"]) => {
		# Read the request body before `Ctx.respond!`. After the response, a
		# read gives `BodyErr`.
		text = req.text!()?
		Ok(Response.from_text(200, text))
	}
	_ => Ok(Response.from_status(404))
}

Count : { n : I64 }

# An `Err` of a handler is a 500 response with no body and a log line with
# `Str.inspect(e)`. To give another status, match the error in the handler.
count! : {} => Try(Response, _)
count! = |{}| {
	got : Try(Count, _)
	got = db.first!("SELECT count(*) AS n FROM items", [])
	match got {
		Ok({ n }) => Ok(Response.from_text(200, n.to_str()))
		Err(NotFound) => Ok(Response.from_status(404))
		Err(e) => {
			Log.error!("count", { error: Str.inspect(e) })
			Ok(Response.from_status(503))
		}
	}
}

# `cron` is the cron expression of the run. `time_ms` is the planned time of
# the run in milliseconds, not the start time. An `Err` is a failed run.
# Production does not run it again.
scheduled! = |s| {
	Log.info!("cron", { cron: s.cron, time_ms: s.time_ms })
	_ = db.run!("DELETE FROM items WHERE expires_ms < ?", [Int(s.time_ms.to_i64_wrap())])?
	Ok({})
}

# One field for each event kind, all optional: `fetch!`, `scheduled!`,
# `queue!`, `email!`, `tail!`, `other!`, `rpc`, `entrypoints`, `objects`.
# A kind with no field gives `Unhandled`: for fetch, a 500 and a log line.
worker = Worker.{ fetch!, scheduled! }

# The platform requires `event!`, not `main!`. It takes each event.
event! = |e| worker.event!(e)
