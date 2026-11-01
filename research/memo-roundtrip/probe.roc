app [] { cbor: "https://github.com/Karakatiza666/roc-cbor/releases/download/0.2.2/Cn5TmeqTbMewyChxexex2F3izTnMriXRv5ZMLVV3eUYb.tar.zst" }

import cbor.Cbor

Curve : [P256, P384, P521]

Material : [
	Rsa({ n : List(U8), e : List(U8) }),
	Ec({ crv : Curve, x : List(U8), y : List(U8) }),
	Okp({ crv : [Ed25519, Ed448], x : List(U8) }),
]

Key : {
	kid : Try(Str, [Missing]),
	alg : Try(Str, [Missing]),
	use : Try(Str, [Missing]),
	key_ops : Try(List(Str), [Missing]),
	material : Material,
}

# A: record with Try fields only
expect {
	v : { kid : Try(Str, [Missing]), alg : Try(Str, [Missing]) }
	v = { kid: Ok("k"), alg: Err(Missing) }
	r : Try({ kid : Try(Str, [Missing]), alg : Try(Str, [Missing]) }, _)
	r = Cbor.parse(Cbor.encode(v))
	r == Ok(v)
}

# B: tag union with a List(U8) record payload
expect {
	v : Material
	v = Rsa({ n: [1, 2, 3], e: [1, 0, 1] })
	r : Try(Material, _)
	r = Cbor.parse(Cbor.encode(v))
	r == Ok(v)
}

# C: tag union with a nested tag
expect {
	v : Material
	v = Ec({ crv: P256, x: [1], y: [2] })
	r : Try(Material, _)
	r = Cbor.parse(Cbor.encode(v))
	r == Ok(v)
}

# D: full key
expect {
	v : Key
	v = { kid: Ok("k"), alg: Ok("RS256"), use: Ok("sig"), key_ops: Err(Missing), material: Rsa({ n: [1, 2, 3], e: [1, 0, 1] }) }
	r : Try(Key, _)
	r = Cbor.parse(Cbor.encode(v))
	r == Ok(v)
}

# E: list of keys
expect {
	v : List(Key)
	v = [{ kid: Ok("k"), alg: Ok("RS256"), use: Ok("sig"), key_ops: Err(Missing), material: Rsa({ n: [1, 2, 3], e: [1, 0, 1] }) }]
	r : Try(List(Key), _)
	r = Cbor.parse(Cbor.encode(v))
	r == Ok(v)
}

# F: Try(List(Str)) Ok
expect {
	v : { key_ops : Try(List(Str), [Missing]) }
	v = { key_ops: Ok(["verify"]) }
	r : Try({ key_ops : Try(List(Str), [Missing]) }, _)
	r = Cbor.parse(Cbor.encode(v))
	r == Ok(v)
}
