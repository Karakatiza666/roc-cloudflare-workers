## `Memo` (MODULES.md 9, PLAN.md 8c). `load!` makes a new id each time (`random_uuid!`), so the same id in two requests
## shows that the second one ran no `load!`. The value has a `U64` of 2^60: it must come back exact (CBOR, MC5).
import pf.Request
import pf.Response
import pf.Memo
import pf.WebCrypto
import pf.Time

Keys : { kid : Str, big : U64, made : Str }

## MODULES.md 15: `load!` has an annotation.
load_keys! : {} => Try(Keys, [LoadErr])
load_keys! = |{}| Ok({ kid: "k1", big: 1_152_921_504_606_846_976, made: WebCrypto.random_uuid!({}) })

keys : Memo(Keys, [LoadErr])
keys = Memo.new("conformance-keys", { max_age_ms: 600_000, load!: load_keys! })

## A short age: a `get!` after 100 ms loads again.
short : Memo(Keys, [LoadErr])
short = Memo.new("conformance-short", { max_age_ms: 50, load!: load_keys! })

MemoRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |_req, path| match path {
		["get"] => show(keys.get!())
		["clear"] => {
			keys.clear!()
			Response.from_text(200, "cleared")
		}
		# Two `get!` of `short`, 100 ms apart: two ids.
		["short"] => {
			a = short.get!()
			Time.sleep!(100)
			b = short.get!()
			Response.from_text(200, "same=${Str.inspect(a == b)}")
		}
		_ => Response.from_text(404, "no route")
	}
}

show : Try(Keys, [LoadErr]) -> Response
show = |r| match r {
	Ok(k) => Response.from_text(200, "Ok kid=${k.kid} big=${k.big.to_str()} made=${k.made}")
	Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
}
