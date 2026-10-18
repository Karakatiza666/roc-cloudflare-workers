app [event!] { pf: platform "../../bench/platform/main.roc" }

## Must not compile: `set!` of a slot of `User` with a record of another type (`name` is a number).
import pf.Worker
import pf.Object
import pf.Response

User : { name : Str }

slot : Object.Attachment(User)
slot = Object.attachment("user")

attach! : Object.Socket => Try({}, [TooLarge])
attach! = |socket| slot.set!(socket, { name: 5 })

fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
