app [event!] { pf: platform "platform/main.roc" }

## N7, a fixture of bench/envread-test.mjs (built by bench/build.sh): the dev-mode check of `bindings`. KV is declared,
## OTHER and OTHER2 are bindings that the app reads and does not declare. `/kv` reads KV, `/other` reads OTHER, `/other2` reads OTHER2, `/var` and
## `/secret` read a text var and a secret, `/json` reads a plain JSON var.
import pf.Worker
import pf.Request
import pf.Response
import pf.Kv
import pf.Env

kv = Kv.text("KV")

other = Kv.text("OTHER")

other2 = Kv.text("OTHER2")

fetch! : Request => Try(Response, _)
fetch! = |req| {
	text = match req.segments() {
		["kv"] => Str.inspect(kv.get!("a"))
		["other"] => Str.inspect(other.get!("a"))
		["other2"] => Str.inspect(other2.get!("a"))
		["var"] => Str.inspect(Env.var!("TEXT_VAR"))
		["secret"] => Str.inspect(Env.secret!("SECRET_VAR").map_ok(|s| s.reveal()))
		["json"] => {
			got : Try({ n : U64 }, _)
			got = Env.json!("JSON_VAR")
			Str.inspect(got)
		}
		_ => "no route"
	}
	Ok(Response.from_text(200, text))
}

worker = Worker.new({ fetch!: fetch!, bindings: [kv.declare()] })

event! = |e| worker.event!(e)
