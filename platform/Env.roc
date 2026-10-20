## The vars and secrets of the Wrangler config (MODULES.md 10): `env[name]`, each one `call!` with no wait.
import Io
import Js
import Secret

Env :: [].{

	## A text var. A name that is not set, or a var that is not text (a JSON var), is `MissingEnv`.
	var! : Str => Try(Str, [Infra([MissingEnv(Str)])])
	var! = |name| match Js.call!([Get(Root("env"), name)]) {
		Ok(Text(s)) => Ok(s)
		_ => Err(Infra(MissingEnv(name)))
	}

	## A JSON var: an object of the Wrangler config (`JSON.stringify` in JS, then `Json.parse`), or a text var with
	## JSON text. A value that does not fit the type is `BadData`.
	json! : Str => Try(a, [Infra([MissingEnv(Str), BadData(Str)])]) where [a.Json.Parseable([InvalidJson(Str), ..errs])]
	json! = |name| {
		text = match Js.call!([Get(Root("env"), name)]) {
			Ok(Text(s)) => s
			Ok(Undefined) | Ok(Null) | Err(_) => return Err(Infra(MissingEnv(name)))
			Ok(_) => match Js.call!([Get(Root("global"), "JSON"), Get(Root("env"), name), Call(Slot(0), "stringify", [Slot(1)])]) {
				Ok(Text(s)) => s
				Ok(other) => return Err(Infra(BadData("Env.json!: ${name} gave ${Str.inspect(other)}")))
				Err(t) => return Err(Infra(BadData("Env.json!: ${name}: ${t.name}: ${t.message}")))
			}
		}
		Json.parse(text).map_err(|e| Infra(BadData(Str.inspect(e))))
	}

	## A secret (a text var of `wrangler secret put`) as a `Secret`, so it does not show in a log line.
	secret! : Str => Try(Secret, [Infra([MissingEnv(Str)])])
	secret! = |name| match Js.call!([Get(Root("env"), name)]) {
		Ok(Text(s)) => Ok(Secret.from_str(s))
		_ => Err(Infra(MissingEnv(name)))
	}
}
