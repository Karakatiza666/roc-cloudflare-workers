app [event!] { pf: platform "../../../bench/platform/main.roc" }

# The worked example of MODULES.md 1, "Migration of stored data": `roc check` must pass.
import pf.Worker
import pf.Object
import pf.Cbor
import pf.Response

Profile : { name : Str, avatar : List(U8), tags : List(Str) }

profile : Object.Cell(Profile)
profile = Object.cell("profile")

# Once, after the deploy that moves from platform 0.0.9: the cell reads strict after it.
migrate! : Object.Self => Try({}, _)
migrate! = |self| match profile.migrate!(self) {
	Ok(Current) | Ok(Migrated) | Err(NotFound) => Ok({})
	Err(Infra(e)) => Err(Infra(e))
}

# The same for bytes that the app keeps itself (an R2 object, a `Kv.bytes` value): read old, write new.
convert : List(U8) -> Try(List(U8), _)
convert = |old| {
	value : Profile
	value = Cbor.parse_legacy(old)?
	Ok(Cbor.encode(value))
}

worker = Worker.new({ fetch!: |_req| Ok(Response.from_text(200, Str.inspect(convert([0xa0]).is_ok()))) })

event! = |e| worker.event!(e)
