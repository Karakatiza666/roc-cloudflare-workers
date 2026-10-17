app [event!] { pf: platform "plat/main.roc" }

## Probe: a custom codec in the app (a `parser_for` method on an app type) with no cbor entry. It names the
## platform aliases `Codec.Format` and `Codec.State` and calls the methods of Cbor by static dispatch (`enc.parse_str(state)`).
import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Sql
import pf.Io
import pf.Codec

db = D1.binding("DB")

## A text id that must start with `id-`.
Tag := Str.{
	is_eq : Tag, Tag -> Bool
	is_eq = |Tag.(a), Tag.(b)| a == b

	parser_for : Codec.Format -> (Codec.State -> Try({ value : Tag, rest : Codec.State }, [InvalidCbor(U64)]))
	parser_for = |enc| |state| {
		parsed = enc.parse_str(state)?
		Ok({ value: Tag.(parsed.value), rest: parsed.rest })
	}
}

Row : { id : I64, tag : Tag }

fetch! : Request => Try(Response, [])
fetch! = |_req| {
	rows : Try(List(Row), _)
	rows = db.all!("SELECT id, tag FROM t", [])
	Ok(Response.from_text(200, Str.inspect(rows)))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)

## Round trip through the custom parser and the wrapped encoder: bytes of `{ id: 7, tag: "id-1" }`.
expect {
	raw = Codec.encode({ id: 7.I64, tag: "id-1" })
	got : Try(Row, _)
	got = Codec.parse(raw)
	got == Ok({ id: 7, tag: Tag.("id-1") })
}
