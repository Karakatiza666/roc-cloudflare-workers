## The Secrets Store binding (MODULES.md 13): `env[name].get()`, one wait. The value is a `Secret` (MODULES.md 10). A secret
## that does not exist is a throw of Workers: `SecretsStoreErr` (the text is not in the Cloudflare docs, PLAN.md 8f part 4).
import Io
import Js
import Secret

SecretsStore :: { name : Str }.{
	binding : Str -> SecretsStore
	binding = |name| SecretsStore.{ name }

	get : SecretsStore -> Io(Secret, [SecretsStoreErr(Io.Thrown)])
	get = |s| Io.new(
		[Get(Root("env"), s.name), Call(Slot(0), "get", [])],
		|r| match r {
			Ok(Text(text)) => Ok(Secret.from_str(text))
			Ok(other) => crash "SecretsStore.get: get() gave ${kind(other)}"
			Err(t) => Err(SecretsStoreErr(t))
		},
	)

	get! : SecretsStore => Try(Secret, [SecretsStoreErr(Io.Thrown)])
	get! = |s| Io.run!(get(s))
}

## The kind of a value, for a crash text: the value can be a secret, so it is never shown.
kind : Js -> Str
kind = |v| match v {
	Undefined => "undefined"
	Null => "null"
	Bool(_) => "a bool"
	Num(_) | Int(_) => "a number"
	Text(_) => "text"
	Bytes(_) => "bytes"
	Arr(_) => "an array"
	Obj(_) => "an object"
	Ref(_) => "a ref"
	Error(_, _) => "an error"
	Packed(_) => "packed data"
}
