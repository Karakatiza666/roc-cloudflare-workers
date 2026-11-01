app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.2/f352LLRKJCZ4JJVEocp3H9e4e6Sxa6Ym5CxZ1GZCpfd.tar.zst" }

## Repro of the Talon slice 106 report: a BLOB read into `List(U8)` and `Cbor.Bytes`.
import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Sql
import pf.Cbor

db = D1.binding("DB")

worker = Worker.new({ fetch!: fetch!, bindings: [db.declare()] })

event! = |e| worker.event!(e)

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	a : Try(List({ bl : List(U8) }), _)
	a = db.all!("SELECT x'0102ff' AS bl", Sql.none)
	b : Try(List({ bl : Cbor.Bytes }), _)
	b = db.all!("SELECT x'0102ff' AS bl", Sql.none)
	c : Try(List({ x : Bool, y : U64 }), _)
	c = db.all!("SELECT 1 AS x, 5 AS y", Sql.none)
	d : Try({ bl : List(U8) }, _)
	d = db.first!("SELECT x'0102ff' AS bl", Sql.none)
	e : Try(List({ bl : List(U8) }), _)
	e = match db.batch!([Sql.stmt("SELECT x'0102ff' AS bl", Sql.none)]) {
		Ok([r]) => r.all().map_err(|x| Str.inspect(x))
		other => Err(Str.inspect(other))
	}
	f : Try(List({ bl : List(U8) }), _)
	f = match db.with_session!(Any) {
		Ok(s) => s.all!("SELECT x'0102ff' AS bl", Sql.none).map_err(|x| Str.inspect(x))
		Err(x) => Err(Str.inspect(x))
	}
	Ok(Response.from_text(200, "first=${Str.inspect(d)} batch=${Str.inspect(e)} session=${Str.inspect(f)} list=${Str.inspect(a)} bytes=${Str.inspect(b.map_ok(|r| r.map(|x| x.bl.to_list())))} xy=${Str.inspect(c)}"))
}
