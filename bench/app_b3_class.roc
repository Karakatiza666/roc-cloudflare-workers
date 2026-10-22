app [event!] { pf: platform "platform/main.roc" }

## Step 8h wave B issue 5, a fixture of bench/cli-test.mjs (built by bench/build.sh).
import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Kv
import pf.Object

## A namespace of the class Ghost, which is not in `objects`: the load must fail.
fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_text(200, "class"))

worker = Worker.new({ fetch!: fetch!, objects: [Object.class("Counter", {}).erase()], bindings: [Object.namespace("GHOSTS", { class: Object.class("Ghost", {}) }).declare()] })

event! = |e| worker.event!(e)
