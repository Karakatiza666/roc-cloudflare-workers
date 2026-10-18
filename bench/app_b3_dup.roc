app [event!] { pf: platform "platform/main.roc" }

## Step 8h wave B issue 5, a fixture of bench/cli-test.mjs (built by bench/build.sh).
import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Kv
import pf.Object

## Two bindings with the name DB: the load must fail.
fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_text(200, "dup"))

worker = Worker.new({ fetch!: fetch!, bindings: [D1.binding("DB").declare(), Kv.text("DB").declare()] })

event! = |e| worker.event!(e)
