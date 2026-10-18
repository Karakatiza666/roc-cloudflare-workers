app [event!] { pf: platform "../../platform/main.roc" }

## Probe (step 8h): `[]` has no derived codec. A nominal empty type with a hand-written codec in its place.
import pf.Worker
import pf.Rpc
import pf.Service
import pf.Response
import pf.Cbor

NoErr := [].{
	parser_for : Cbor.Format -> (Cbor.State -> Try({ value : NoErr, rest : Cbor.State }, [InvalidCbor(U64)]))
	parser_for = |_| |_state| Err(InvalidCbor(0))

	encoder_for : Cbor.Format -> (NoErr, List(U8) -> Try(List(U8), []))
	encoder_for = |_| |_v, out| Ok(out)
}

ping : Rpc({}, U64, NoErr)
ping = Rpc.method("ping")

ping! : {}, {} => Try(U64, NoErr)
ping! = |{}, {}| Ok(1)

fetch! = |_req| Ok(Response.from_text(200, Str.inspect(Service.binding("SELF").call!(ping, {}))))

worker = Worker.new({ fetch!, rpc: [ping.on(ping!)] })

event! : Worker.Event => Worker.Outcome
event! = |e| worker.event!(e)
