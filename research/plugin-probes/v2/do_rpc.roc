app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Rpc
import pf.Service

Other := []

Admin := []

other_api : Rpc.Iface(Other)
other_api = Rpc.iface("Other")

admin_api : Rpc.Iface(Admin)
admin_api = Rpc.iface("Admin")

lookup : Rpc(Other, { key : Str }, Str, [Unknown])
lookup = other_api.method("lookup")

ping : Rpc.Iface(iface) -> Rpc(iface, {}, Str, Rpc.NoErr)
ping = |i| i.method("ping")

purge : Rpc(Admin, { prefix : Str }, U64, Rpc.NoErr)
purge = admin_api.method("purge")

other = Service.binding_with("OTHER", other_api, { service: "other-worker" })

admin = Service.binding_with("ADMIN", admin_api, { service: "this-worker", entrypoint: "Admin" })

fetch! : Request => Try(Response, _)
fetch! = |req| match req.segments() {
	["lookup", key] =>
		match other.call!(lookup, { key: key }) {
			Ok(v) => Ok(Response.from_text(200, v))
			Err(Remote(Unknown)) => Ok(Response.from_status(404))
			Err(Infra(e)) => Err(Infra(e))
		}

	["admin", ..] => Ok(admin.fetch!(req)?)
	_ => Ok(Response.from_status(404))
}

admin_entrypoint = Rpc.entrypoint("Admin", {
	fetch!: |_req| Ok(Response.from_text(200, "admin")),
	rpc: [
		purge.on_worker(|{ prefix }| Ok(prefix.count_utf8_bytes())),
	],
})

worker = Worker.new({
	fetch!: fetch!,
	rpc: [
		lookup.on_worker(|{ key }| if key == "a" Ok("alpha") else Err(Unknown)),
	],
	entrypoints: [admin_entrypoint],
	bindings: [other.declare(), admin.declare()],
})

event! = |e| worker.event!(e)
