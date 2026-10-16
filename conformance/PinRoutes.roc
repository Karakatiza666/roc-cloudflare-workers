## The pin table (API.md RS2, PLAN.md 8c): `Io.pin!`, `Io.pinned!`, `Io.unpin!` (`Js.pin!` and its pair in API.md).
## A route answers `Str.inspect` of the result. `checks/pin.mjs` checks them. A pinned `CryptoKey` (a ref): see
## `WebCryptoRoutes.roc`, `pin` and `use`.
import pf.Request
import pf.Response
import pf.Io
import pf.Time
import Q

PinRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| {
		name = Q.text(req, "name")
		match path {
			["pin"] => show(Io.pin!(name, Text(Q.text(req, "v")), { max_age_ms: 600_000 }))
			["pinned"] => show(Io.pinned!(name))
			["unpin"] => {
				Io.unpin!(name)
				Response.from_text(200, "unpinned")
			}
			# A pin with an age of 50 ms: `pinned!` at once, then after 100 ms.
			["age"] => {
				_ = Io.pin!(name, Int(7), { max_age_ms: 50 })
				a = Io.pinned!(name)
				Time.sleep!(100)
				b = Io.pinned!(name)
				Response.from_text(200, "${Str.inspect(a)} ${Str.inspect(b)}")
			}
			["full"] => full!({})
			_ => Response.from_text(404, "no route")
		}
	}
}

show : Try(a, e) -> Response
show = |r| Response.from_text(200, Str.inspect(r))

## Pins until the table is full (the shim option `pinLimit`, default 1,000 entries), then unpins all of them.
full! : {} => Response
full! = |{}| {
	var $n = 0.U64
	var $err = ""
	while $n < 2_000 and $err == "" {
		match Io.pin!("full-${$n.to_str()}", Null, { max_age_ms: 60_000 }) {
			Ok({}) => {
				$n = $n + 1
			}
			Err(PinErr(t)) => {
				$err = "PinErr ${t.name}: ${t.message}"
			}
		}
	}
	var $i = 0.U64
	while $i < $n {
		Io.unpin!("full-${$i.to_str()}")
		$i = $i + 1
	}
	Response.from_text(200, "pinned=${$n.to_str()} ${$err}")
}
