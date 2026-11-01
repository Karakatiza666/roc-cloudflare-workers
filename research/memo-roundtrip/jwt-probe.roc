app [main!] {
	cbor: "https://github.com/Karakatiza666/roc-cbor/releases/download/0.2.2/Cn5TmeqTbMewyChxexex2F3izTnMriXRv5ZMLVV3eUYb.tar.zst",
	jwt: "/home/george/dev/Karakatiza666/roc-jwt/package/main.roc",
}

import cbor.Cbor
import jwt.Jwk
import "jwks.json" as text : Str

main! = |_args| {
	keys = Jwk.parse_set(text) ?? []
	bytes = Cbor.encode(keys)
	r : Try(List(Jwk.Key), _)
	r = Cbor.parse(bytes)
	echo!("keys=${keys.len().to_str()} len=${bytes.len().to_str()} same=${Str.inspect(r == Ok(keys))}\n")
	match r {
		Ok(_) => {}
		Err(e) => echo!("err=${Str.inspect(e)}\n")
	}
	Ok({})
}
