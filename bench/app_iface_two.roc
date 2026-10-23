app [event!] { pf: platform "platform/main.roc" }

## A fixture of bench/iface-test.mjs (built by bench/build.sh): the class Mixed serves methods of two interfaces
## (two Rpc.iface names). The load of the app fails (MODULES.md 3).
import pf.Worker
import pf.Request
import pf.Response
import pf.Rpc
import pf.Object

Alpha := []

alpha_iface : Rpc.Iface(Alpha)
alpha_iface = Rpc.iface("Alpha")

beta_iface : Rpc.Iface(Alpha)
beta_iface = Rpc.iface("Beta")

one : Rpc(Alpha, {}, {}, Rpc.NoErr)
one = alpha_iface.method("one")

two : Rpc(Alpha, {}, {}, Rpc.NoErr)
two = beta_iface.method("two")

mixed : Object.Class(Alpha)
mixed = Object.class("Mixed", { rpc: [one.on(|_, _| Ok({})), two.on(|_, _| Ok({}))] })

fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_text(200, "two"))

worker = Worker.new({ fetch!: fetch!, objects: [mixed.erase()] })

event! = |e| worker.event!(e)
