app [event!] { pf: platform "../../bench/platform/main.roc" }

## The control of `infra_precise_bad.roc` (N5 G1a): the closed `describe` has the arms of the tags of `Kv.get!` only. It compiles only when the
## error of `Kv.get!` fits it. `conformance/must-not-compile.sh` runs `roc check` on it.
import pf.Worker
import pf.Kv
import pf.Response
import pf.Io

describe : [NotFound, Infra([KvErr(Io.Thrown), BadData(Str), TooLarge])] -> Str
describe = |e| match e {
	NotFound => "none"
	Infra(KvErr(_)) => "kv"
	Infra(BadData(_)) => "bad"
	Infra(TooLarge) => "big"
}

read! : {} => Str
read! = |{}| match Kv.text("KV").get!("k") {
	Ok(v) => v
	Err(e) => describe(e)
}

fetch! = |_req| Ok(Response.from_text(200, read!({})))

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
