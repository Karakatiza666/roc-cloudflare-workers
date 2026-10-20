## The Version Metadata binding (MODULES.md 13): `env[name]` is a plain object `{ id, tag, timestamp }`. One `call!`, no wait.
## `timestamp` is ISO text: `Date.parse` in the same program gives the ms (MC10). A binding that is not in the config
## gives `undefined` fields (OP7): that is a crash with the name of the binding, not a value.
import Io
import Js

Version :: { name : Str }.{
	binding : Str -> Version
	binding = |name| Version.{ name }

	## The binding for the manifest (`Worker.new({ bindings: [...] })`, MODULES.md 3): the kind `version`.
	declare : Version -> { name : Str, kind : Str, props : List((Str, Str)) }
	declare = |b| { name: b.name, kind: "version", props: [] }

	metadata! : Version => { id : Str, tag : Str, timestamp_ms : U64 }
	metadata! = |v| match Js.call!([
		Get(Root("env"), v.name),
		Get(Slot(0), "id"),
		Get(Slot(0), "tag"),
		Get(Slot(0), "timestamp"),
		Get(Root("global"), "Date"),
		Call(Slot(4), "parse", [Slot(3)]),
		Record([("id", Slot(1)), ("tag", Slot(2)), ("timestamp_ms", Slot(5))]),
	]) {
		Ok(js) => match meta_of(js) {
			Ok(m) => m
			Err(why) => crash "Version.metadata!: ${v.name}: ${why}"
		}
		Err(t) => crash "Version.metadata!: ${v.name}: ${t.name}: ${t.message}"
	}
}

## The record of the program as the metadata. `tag` is `""` when the version has no tag (the local value).
meta_of : Js -> Try({ id : Str, tag : Str, timestamp_ms : U64 }, Str)
meta_of = |js| match js {
	Obj(fields) => match (field(fields, "id"), field(fields, "tag"), field(fields, "timestamp_ms")) {
		(Text(id), tag, Int(ms)) => {
			text = match tag {
				Text(t) => t
				_ => ""
			}
			match ms.to_u64_try() {
				Ok(t) => Ok({ id, tag: text, timestamp_ms: t })
				Err(_) => Err("the timestamp is before 1970")
			}
		}
		(Text(_), _, other) => Err("the timestamp is not a date: ${Str.inspect(other)}")
		_ => Err("the binding is not in env, or it is not a version metadata object")
	}
	_ => Err("the program gave ${Str.inspect(js)}")
}

field : List((Str, Js)), Str -> Js
field = |fields, name| match fields.find_first(|(k, _)| k == name) {
	Ok((_, v)) => v
	Err(_) => Undefined
}

expect meta_of(Obj([("id", Text("v1")), ("tag", Text("")), ("timestamp_ms", Int(1_760_000_000_000))])) == Ok({ id: "v1", tag: "", timestamp_ms: 1_760_000_000_000 })
expect meta_of(Obj([("id", Text("v1")), ("tag", Undefined), ("timestamp_ms", Int(5))])) == Ok({ id: "v1", tag: "", timestamp_ms: 5 })
expect meta_of(Obj([("id", Undefined), ("tag", Undefined), ("timestamp_ms", Undefined)])).is_err()
expect meta_of(Obj([("id", Text("v1")), ("tag", Text("t")), ("timestamp_ms", Num(1.5))])).is_err()
