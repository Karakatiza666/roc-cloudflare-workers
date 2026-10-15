import Io

## WebCrypto. Not `Crypto`: that name is a builtin module (`clash/`). A key is its material,
## and each operation imports it in the same crossing, so a key is plain data.
WebCrypto :: [].{
	verify : { alg : WebCrypto.Alg, key : WebCrypto.Key, signature : List(U8), data : List(U8) } -> Io({}, [BadSignature, CryptoErr(Io.Thrown), BadData(Str)])
	verify = |v| {
		sig = Str.from_utf8(v.signature) ?? "?"
		Io.new(["crypto.verify", Str.inspect(v.alg), sig], |r| match r {
			Ok(bytes) if bytes == [0xf5] => Ok({})
			Ok(_) => Err(BadSignature)
			Err(t) => Err(CryptoErr(t))
		})
	}

	verify! : { alg : WebCrypto.Alg, key : WebCrypto.Key, signature : List(U8), data : List(U8) } => Try({}, [BadSignature, CryptoErr(Io.Thrown), BadData(Str)])
	verify! = |v| Io.run!(verify(v))

	Key : [Jwk(Str), Raw(List(U8)), Pkcs8(List(U8)), Spki(List(U8))]

	Alg : [Hmac(WebCrypto.Hash), RsaPkcs1(WebCrypto.Hash), RsaPss(WebCrypto.Hash), Ecdsa(WebCrypto.Hash), Ed25519]

	Hash : [Sha256, Sha384, Sha512]
}
