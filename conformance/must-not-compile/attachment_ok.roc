app [event!] { pf: platform "../../bench/platform/main.roc" }

## Control of attachment_bad.roc: `set!` with a value of the type of the slot compiles.
import pf.Worker
import pf.Object
import pf.Response

User : { name : Str }

slot : Object.Attachment(User)
slot = Object.attachment("user")

attach! : Object.Socket => Try({}, [Infra([TooLarge])])
attach! = |socket| slot.set!(socket, { name: "a" })

fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
