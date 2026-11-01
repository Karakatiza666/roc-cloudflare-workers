app [event!] { pf: platform "../../platform/main.roc" }

## Narrow the dev backend failure: pure `Cbor.parse` of fixed bytes, no D1.
import pf.Worker
import pf.Request
import pf.Response
import pf.Cbor

## [ { "bl": [1, 2, 255] } ]
rows_255 : List(U8)
rows_255 = [0x81, 0xa1, 0x62, 0x62, 0x6c, 0x83, 0x01, 0x02, 0x18, 0xff]

## [ { "bl": [1, 2, 3] } ]
rows_3 : List(U8)
rows_3 = [0x81, 0xa1, 0x62, 0x62, 0x6c, 0x83, 0x01, 0x02, 0x03]

## [1, 2, 3]
list_3 : List(U8)
list_3 = [0x83, 0x01, 0x02, 0x03]

## [1, 2, 255]
list_255 : List(U8)
list_255 = [0x83, 0x01, 0x02, 0x18, 0xff]

## [1, 2, 3] as U64
fetch! : Request => Try(Response, _)
fetch! = |_req| {
	a : Try(List({ bl : List(U8) }), _)
	a = Cbor.parse(rows_255)
	b : Try(List({ bl : List(U8) }), _)
	b = Cbor.parse(rows_3)
	c : Try(List(U8), _)
	c = Cbor.parse(list_3)
	d : Try(List(U8), _)
	d = Cbor.parse(list_255)
	e : Try(List(U64), _)
	e = Cbor.parse(list_3)
	f : Try(U8, _)
	f = Cbor.parse([0x03])
	g : Try(U8, _)
	g = Cbor.parse([0x18, 0xff])
	h : Try(List(U8), _)
	h = Cbor.parse([0x43, 0x01, 0x02, 0xff])
	Ok(Response.from_text(200, "a=${Str.inspect(a)} b=${Str.inspect(b)} c=${Str.inspect(c)} d=${Str.inspect(d)} e=${Str.inspect(e)} f=${Str.inspect(f)} g=${Str.inspect(g)} h=${Str.inspect(h)}"))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
