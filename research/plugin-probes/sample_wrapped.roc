## The app that roc_check wraps bare cloudflare-workers source in, when the
## caller names the scope and the code has no header.
##
## Everything above `@user-code` is the prelude. roc_check adds each
## `@default` block below it only when the submitted code does not define
## that name. So a bare `fetch!` gets a Worker and an `event!`, and code that
## defines its own `worker` or `event!` keeps them.
app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

# The compiler does not warn about an unused import. The scaffold imports each
# exposed module, so a snippet that uses D1 or Object compiles as submitted.
import pf.Ai
import pf.Analytics
import pf.Assets
import pf.Body
import pf.Cache
import pf.Cbor
import pf.Ctx
import pf.D1
import pf.Email
import pf.Env
import pf.Http
import pf.Hyperdrive
import pf.Io
import pf.Js
import pf.Kv
import pf.Log
import pf.Memo
import pf.Native
import pf.Object
import pf.Queue
import pf.R2
import pf.RateLimit
import pf.Request
import pf.Response
import pf.Rpc
import pf.Secret
import pf.SecretsStore
import pf.Service
import pf.Sql
import pf.Tcp
import pf.Time
import pf.Vectorize
import pf.Version
import pf.WebCrypto
import pf.WebSocket
import pf.Worker
import pf.Workflows

db = D1.binding("DB")

Item : { id : I64, name : Str }

fetch! : Request => Try(Response, _)
fetch! = |req| match (req.method, req.segments()) {
	(GET, ["items", id_text]) => {
		id = I64.from_str(id_text) ? |_| BadId
		item : Item
		item = db.first!("SELECT id, name FROM items WHERE id = ?", [Int(id)])?
		Ok(Response.from_json(200, item))
	}
	_ => Ok(Response.from_status(404))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
