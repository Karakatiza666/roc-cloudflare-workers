import Io
import Js

## WebCrypto. Not `Crypto`: that name is a builtin module (`clash/`). A key is its material,
## and each operation imports it in the same crossing, so a key is plain data. `Imported` is a ref.
WebCrypto :: [].{
	verify : { alg : WebCrypto.Alg, key : WebCrypto.Key, signature : List(U8), data : List(U8) } -> Io({}, [BadSignature, CryptoErr(Io.Thrown)])
	verify = |v| {
		sig = Str.from_utf8(v.signature) ?? "?"
		Io.new(["crypto.verify", Str.inspect(v.alg), sig, key_text(v.key)], |r| match r {
			Ok(bytes) if bytes == [0xf5] => Ok({})
			Ok(_) => Err(BadSignature)
			Err(t) => Err(CryptoErr(t))
		})
	}

	verify! : { alg : WebCrypto.Alg, key : WebCrypto.Key, signature : List(U8), data : List(U8) } => Try({}, [BadSignature, CryptoErr(Io.Thrown)])
	verify! = |v| Io.run!(verify(v))

	## `importKey`, one wait: an `Imported` key, for many operations in one task.
	import_key! : WebCrypto.KeyAlg, WebCrypto.Key => Try(WebCrypto.Key, [CryptoErr(Io.Thrown)])
	import_key! = |alg, key| {
		ref : U32
		ref = Io.run!(Io.tree(["crypto.import", Str.inspect(alg), key_text(key)], |t| CryptoErr(t)))?
		Ok(Imported(Js.Ref.fake(ref)))
	}

	## `timingSafeEqual`, sync.
	timing_safe_equal! : List(U8), List(U8) => Bool
	timing_safe_equal! = |a, b| match Io.run!(Io.tree(["crypto.equal", Str.inspect(a), Str.inspect(b)], |t| t)) {
		Ok(same) => same
		Err(_) => Bool.False
	}

	## `getRandomValues`, sync: new bytes.
	random! : U64 => List(U8)
	random! = |n| Io.run!(Io.tree(["crypto.random", n.to_str()], |t| t)) ?? []

	## `randomUUID`, sync.
	random_uuid! : {} => Str
	random_uuid! = |{}| Io.run!(Io.tree(["crypto.uuid"], |t| t)) ?? ""

	Key : [Jwk(Str), Raw(List(U8)), Pkcs8(List(U8)), Spki(List(U8)), Imported(Js.Ref)]

	Alg : [Hmac(WebCrypto.Hash), RsaPkcs1(WebCrypto.Hash), RsaPss({ hash : WebCrypto.Hash, salt_length_bytes : U32 }), Ecdsa(WebCrypto.Curve, WebCrypto.Hash), Ed25519]

	KeyAlg : [Hmac(WebCrypto.Hash), RsaPkcs1(WebCrypto.Hash), RsaPss(WebCrypto.Hash), RsaOaep(WebCrypto.Hash), Ecdsa(WebCrypto.Curve), Ecdh(WebCrypto.Curve), Ed25519, X25519, AesGcm, AesCbc, AesCtr, Pbkdf2, Hkdf]

	Hash : [Sha256, Sha384, Sha512]

	Curve : [P256, P384, P521]
}

key_text : WebCrypto.Key -> Str
key_text = |k| match k {
	Imported(ref) => "ref:${ref.to_str()}"
	_ => "data"
}
