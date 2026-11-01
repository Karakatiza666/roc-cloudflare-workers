## `Memo` (MODULES.md 9, PLAN.md 8c). `load!` makes a new id each time (`random_uuid!`), so the same id in two requests
## shows that the second one ran no `load!`. The value has a `U64` of 2^60: it must come back exact (CBOR, MC5).
import pf.Request
import pf.Response
import pf.Memo
import pf.WebCrypto
import pf.Time
import pf.Cbor
import Q

Keys : { kid : Str, big : U64, made : Str }

## MODULES.md 15: `load!` has an annotation.
load_keys! : () => Try(Keys, [LoadErr])
load_keys! = || Ok({ kid: "k1", big: 1_152_921_504_606_846_976, made: WebCrypto.random_uuid!() })

keys : Memo(Keys)
keys = Memo.new("conformance-keys", { max_age_ms: 600_000 })

## The clock check (checks/clock.mjs): an age of 60 s on the clock of the shim (option `now`), not on real time.
clock : Memo(Keys)
clock = Memo.new("conformance-clock", { max_age_ms: 60_000 })

## A short age: a `get!` after 100 ms loads again.
short : Memo(Keys)
short = Memo.new("conformance-short", { max_age_ms: 50 })

## The shape of `List(Jwk.Key)` of roc-jwt 0.0.1 (a local copy: no dependency on roc-jwt). Talon slice 108b, P1.
Curve : [P256, P384, P521]

Material : [
	Rsa({ n : List(U8), e : List(U8) }),
	Ec({ crv : Curve, x : List(U8), y : List(U8) }),
	Okp({ crv : [Ed25519, Ed448], x : List(U8) }),
]

Jwk : {
	kid : Try(Str, [Missing]),
	alg : Try(Str, [Missing]),
	use : Try(Str, [Missing]),
	key_ops : Try(List(Str), [Missing]),
	material : Material,
}

Jwks : { made : Str, keys : List(Jwk) }

load_jwks! : () => Try(Jwks, [LoadErr])
load_jwks! = || Ok({ made: WebCrypto.random_uuid!(), keys: jwk_list })

jwk_list : List(Jwk)
jwk_list = [
	{ kid: Ok("a"), alg: Ok("RS256"), use: Ok("sig"), key_ops: Err(Missing), material: Rsa({ n: List.repeat(0xc5, 256), e: [1, 0, 1] }) },
	{ kid: Err(Missing), alg: Err(Missing), use: Err(Missing), key_ops: Ok(["verify"]), material: Ec({ crv: P256, x: List.repeat(1, 32), y: List.repeat(2, 32) }) },
	{ kid: Ok("c"), alg: Err(Missing), use: Err(Missing), key_ops: Err(Missing), material: Okp({ crv: Ed25519, x: List.repeat(3, 32) }) },
]

jwks : Memo(Jwks)
jwks = Memo.new("conformance-jwks", { max_age_ms: 600_000 })

## A type that never round-trips: `Err(Null)` in a record field writes no key, and a `Try(a, [Null])` field is
## required (roc-cbor rules N4, N5). `get!` logs one line for the name, does not pin, and runs `load!` each time.
Unreadable : { made : Str, note : Try(Str, [Null]) }

load_unreadable! : () => Try(Unreadable, [LoadErr])
load_unreadable! = || Ok({ made: WebCrypto.random_uuid!(), note: Err(Null) })

unreadable : Memo(Unreadable)
unreadable = Memo.new("conformance-unreadable", { max_age_ms: 600_000 })

## An older type after a deploy: two `Memo` constants with one name and two types. The value of `older` does not
## parse as `newer`, so `newer.get!` loads again with no log line, pins its own value, and the next `get!` reads it.
older : Memo({ made : Str, kid : Str })
older = Memo.new("conformance-deploy", { max_age_ms: 600_000 })

newer : Memo({ made : Str, big : U64 })
newer = Memo.new("conformance-deploy", { max_age_ms: 600_000 })

load_older! : () => Try({ made : Str, kid : Str }, [LoadErr])
load_older! = || Ok({ made: WebCrypto.random_uuid!(), kid: "k1" })

load_newer! : () => Try({ made : Str, big : U64 }, [LoadErr])
load_newer! = || Ok({ made: WebCrypto.random_uuid!(), big: 7 })

## Small integer types with values from the request (not constants), in a record and a tag payload.
Small : { u8 : List(U8), i8 : List(I8), u16 : List(U16), i16 : List(I16), tag : [Bin(List(U8)), Txt(Str)] }

MemoRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| match path {
		["get"] => show(keys.get!(load_keys!))
		["clear"] => {
			keys.clear!()
			Response.from_text(200, "cleared")
		}
		["clock"] => show(clock.get!(load_keys!))
		# Two `get!` of `short`, 100 ms apart: two ids.
		["short"] => {
			a = short.get!(load_keys!)
			Time.sleep!(100)
			b = short.get!(load_keys!)
			Response.from_text(200, "same=${Str.inspect(a == b)}")
		}
		["jwks"] => match jwks.get!(load_jwks!) {
			Ok(v) => Response.from_text(200, "Ok keys=${v.keys.len().to_str()} made=${v.made}")
			Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
		}
		["unreadable"] => match unreadable.get!(load_unreadable!) {
			Ok(v) => Response.from_text(200, "Ok made=${v.made}")
			Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
		}
		["deploy", "older"] => match older.get!(load_older!) {
			Ok(v) => Response.from_text(200, "Ok made=${v.made}")
			Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
		}
		["deploy", "newer"] => match newer.get!(load_newer!) {
			Ok(v) => Response.from_text(200, "Ok made=${v.made}")
			Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
		}
		["deploy", "clear"] => {
			newer.clear!()
			Response.from_text(200, "cleared")
		}
		# `?n=`: each value is from n, so the compiler cannot fold the round trip.
		["small"] => {
			n = Q.num(req, "n")
			v : Small
			v = { u8: [n.to_u8_wrap(), 255], i8: [n.to_i8_wrap(), -128], u16: [n.to_u16_wrap(), 65535], i16: [n.to_i16_wrap(), -32768], tag: Bin([n.to_u8_wrap(), 0]) }
			back : Try(Small, _)
			back = Cbor.parse(Cbor.encode(v))
			match back {
				Ok(b) => Response.from_text(200, "same=${Str.inspect(b == v)}")
				Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
			}
		}
		# Encode then parse in wasm, with no pin table.
		["roundtrip"] => {
			v = { made: WebCrypto.random_uuid!(), keys: jwk_list }
			back : Try(Jwks, _)
			back = Cbor.parse(Cbor.encode(v))
			match back {
				Ok(b) => Response.from_text(200, "same=${Str.inspect(b == v)}")
				Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
			}
		}
		_ => Response.from_text(404, "no route")
	}
}

show : Try(Keys, [LoadErr]) -> Response
show = |r| match r {
	Ok(k) => Response.from_text(200, "Ok kid=${k.kid} big=${k.big.to_str()} made=${k.made}")
	Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
}
