app [main!] { cbor: "https://github.com/Karakatiza666/roc-cbor/releases/download/0.5.0/B5U2mPsWTtuxfCRMzqQxio2ecDv7CAzCoyEMENMh4FNF.tar.zst" }

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

main! = |args| {
	k = args.len().to_u8_wrap()
	v : List(Key)
	v = [{ kid: Ok("k"), alg: Ok("RS256"), use: Ok("sig"), key_ops: Err(Missing), material: Rsa({ n: List.repeat(k, 256), e: [1, 0, 1] }) }, { kid: Err(Missing), alg: Err(Missing), use: Err(Missing), key_ops: Ok(["verify"]), material: Ec({ crv: P256, x: [k], y: [2] }) }]
	bytes = Cbor.encode(v)
	r : Try(List(Key), _)
	r = Cbor.parse(bytes)
	echo!("len=${bytes.len().to_str()} same=${Str.inspect(r == Ok(v))}\n")
	match r {
		Ok(_) => {}
		Err(e) => echo!("err=${Str.inspect(e)}\n")
	}
	Ok({})
}
