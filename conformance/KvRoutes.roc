## `Kv` and `Kv.Cell` (MODULES.md 5.2, 9, PLAN.md 8f). The binding `KV` is in `checks/kv.mjs`, which also writes the big value.
## Each route answers `Ok <text>` or `Err <the error>`. `?k=` is the key, `?v=` the value, `?max=` the limit, `?ttl=` and
## `?expires=` times in ms. The twin of a route is `<name>_io`.
import pf.Request
import pf.Response
import pf.Kv
import pf.Io
import Q

Prefs : { theme : Str, n : U64, big : U64 }
Meta : { tag : Str, n : U64 }
Ratio : { name : Str, ratio : F64 }

prefs : Kv(Prefs)
prefs = Kv.json("KV")

plain : Kv(Str)
plain = Kv.text("KV")

ratios : Kv(Ratio)
ratios = Kv.json("KV")

raw : Kv(List(U8))
raw = Kv.bytes("KV")

cell : Kv.Cell(Prefs)
cell = prefs.cell("cell-prefs")

KvRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| {
		k = Q.text(req, "k")
		v = Q.text(req, "v")
		max = Q.num(req, "max")
		ttl = Q.num(req, "ttl")
		expires = Q.num(req, "expires")
		meta = Kv.Metadata.of({ tag: v, n: 9.U64 })
		value = { theme: v, n: 3, big: 1_152_921_504_606_846_976 }
		match path {
			["get"] => show(plain.get!(k))
			["get_io"] => show(Io.run!(plain.get(k)))
			["get_or"] => show(plain.get_or!(k, "default"))
			["get_or_io"] => show(Io.run!(plain.get_or(k, "default")))
			# A record with an `F64` field is JSON-encodable (MODULES.md 15). `?v=nan` is a `NaN`: `BadData`, nothing is sent.
			["f64_put"] => show(ratios.put!(k, { name: v, ratio: if v == "nan" 0.0 / 0.0 else 0.5 }))
			["f64_get"] => show(ratios.get!(k))
			["f64_response"] => Response.from_json(200, { name: v, ratio: if v == "nan" 0.0 / 0.0 else 0.5 })
			["len"] => len(plain.get!(k))
			["len_with"] => len(plain.get_with!(k, { max_bytes: max }))
			["len_with_io"] => len(Io.run!(plain.get_with(k, { max_bytes: max })))
			["get_cache"] => show(plain.get_with!(k, { cache_ttl_ms: ttl }))
			["put"] => show(plain.put!(k, v))
			["put_io"] => show(Io.run!(plain.put(k, v)))
			["put_ttl"] => show(plain.put_with!(k, v, { ttl_ms: ttl }))
			["put_ttl_io"] => show(Io.run!(plain.put_with(k, v, { ttl_ms: ttl })))
			["put_expires"] => show(plain.put_with!(k, v, { expires_ms: expires }))
			["put_meta"] => show(plain.put_with!(k, v, { metadata: meta }))
			["delete"] => show(plain.delete!(k))
			["delete_io"] => show(Io.run!(plain.delete(k)))
			["json_put"] => show(prefs.put!(k, value))
			["json_get"] => show(prefs.get!(k))
			["bytes_put"] => show(raw.put!(k, [0, 1, 254, 255]))
			["bytes_get"] => show(raw.get!(k))
			["get_meta"] => meta_of(plain.get_with_metadata!(k))
			["get_meta_io"] => meta_of(Io.run!(plain.get_with_metadata(k)))
			["get_meta_with"] => meta_of(plain.get_with_metadata_with!(k, { max_bytes: max }))
			["get_meta_with_io"] => meta_of(Io.run!(plain.get_with_metadata_with(k, { max_bytes: max })))
			["list"] => list(plain.list!({ prefix: k }))
			["list_page"] => list(plain.list!({ prefix: k, limit: 2, cursor: v }))
			["list_io"] => list(Io.run!(plain.list({ prefix: k })))
			["list_all"] => list(plain.list!({}))
			# The Cell: one key as a value.
			["cell_set"] => show(cell.set!(value))
			["cell_set_io"] => show(Io.run!(cell.set(value)))
			["cell_set_ttl"] => show(cell.set_with!(value, { ttl_ms: ttl }))
			["cell_set_ttl_io"] => show(Io.run!(cell.set_with(value, { ttl_ms: ttl })))
			["cell_get"] => show(cell.get!())
			["cell_get_or"] => show(cell.get_or!({ theme: "none", n: 0, big: 0 }))
			["cell_get_or_io"] => show(Io.run!(cell.get_or({ theme: "none", n: 0, big: 0 })))
			["cell_get_io"] => show(Io.run!(cell.get()))
			["cell_delete"] => show(cell.delete!())
			["cell_delete_io"] => show(Io.run!(cell.delete()))
			_ => Response.from_text(404, "no route")
		}
	}
}

show : Try(a, e) -> Response
show = |r| Response.from_text(
	200,
	match r {
		Ok(x) => "Ok ${Str.inspect(x)}"
		Err(e) => "Err ${Str.inspect(e)}"
	},
)

## The size of a big value, not the value.
len : Try(Str, e) -> Response
len = |r| Response.from_text(
	200,
	match r {
		Ok(s) => "Ok len=${s.count_utf8_bytes().to_str()}"
		Err(e) => "Err ${Str.inspect(e)}"
	},
)

## The value and the metadata of `get_with_metadata!`, typed as `Meta` (MC7).
meta_of : Try({ value : Str, metadata : Try(Meta, [Missing]) }, e) -> Response
meta_of = |r| show(r)

list : Try({ keys : List(Kv.Key), next : [More(Str), Done] }, e) -> Response
list = |r| match r {
	Ok(page) => {
		keys = page.keys.map(
			|key| {
				meta_text = match key.metadata {
					Ok(m) => {
						parsed : Try(Meta, _)
						parsed = m.parse()
						Str.inspect(parsed)
					}
					Err(Missing) => "none"
				}
				"${key.name}:${Str.inspect(key.expires_ms)}:${meta_text}"
			},
		)
		Response.from_text(200, "Ok ${Str.inspect(keys)} ${Str.inspect(page.next)}")
	}
	Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
}
