## Log lines (MODULES.md 11): one JSON line `{"level":"info","msg":...,<fields>}` to `console.info`, `console.warn` or
## `console.error`, so Workers Logs gets the level and can filter on the fields. One `call!` each, no wait.
## The fields are a record with a JSON codec: a record with a `Secret` in it does not compile (MODULES.md 10).
import Io
import Js

Log :: [].{
	info! : Str, a => {} where [a.Json.Encodable(enc)]
	info! = |msg, fields| write!("info", line("info", msg, fields))

	warn! : Str, a => {} where [a.Json.Encodable(enc)]
	warn! = |msg, fields| write!("warn", line("warn", msg, fields))

	error! : Str, a => {} where [a.Json.Encodable(enc)]
	error! = |msg, fields| write!("error", line("error", msg, fields))
}

## A value that JSON cannot show (a `NaN` in an `F64`) goes as `{"fields_error": "NaN"}`: a log line never fails.
## The fields of a record go after `level` and `msg`. A value that is not a JSON object goes in the field `fields`.
line : Str, Str, a -> Str where [a.Json.Encodable(enc)]
line = |level, msg, fields| {
	head = "{\"level\":${Json.to_str(level)},\"msg\":${Json.to_str(msg)}"
	rest = match Json.to_str_try(fields) {
		Ok(text) => text
		Err(e) => "{\"fields_error\":${Json.to_str(Str.inspect(e))}}"
	}
	if rest == "{}" {
		"${head}}"
	} else if rest.starts_with("{") {
		"${head},${rest.drop_prefix("{")}"
	} else {
		"${head},\"fields\":${rest}}"
	}
}

## `console.<method>(line)`. A throw is a platform bug: a crash.
write! : Str, Str => {}
write! = |method, text| match Js.call!([Get(Root("global"), "console"), Call(Slot(0), method, [Lit(Text(text))])]) {
	Ok(_) => {}
	Err(t) => crash "Log: console.${method}: ${t.name}: ${t.message}"
}

expect line("info", "published", { pkg: "a/b", ms: 12.U64 }) == "{\"level\":\"info\",\"msg\":\"published\",\"ms\":12,\"pkg\":\"a/b\"}"
expect line("warn", "x \"y\"", {}) == "{\"level\":\"warn\",\"msg\":\"x \\\"y\\\"\"}"
expect line("warn", "n", { r: 0.0.F64 / 0.0.F64 }) == "{\"level\":\"warn\",\"msg\":\"n\",\"fields_error\":\"NaN\"}"
expect line("error", "n", 5.U64) == "{\"level\":\"error\",\"msg\":\"n\",\"fields\":5}"
