## `WebCrypto` (MODULES.md 10). Each route answers a text that `checks/webcrypto.mjs` compares. A key or a signature that
## Node made comes as hex in the query (`?priv=`, `?pub=`, `?jwk=`, `?pkcs8=`, `?sig=`, `?data=`).
import pf.Request
import pf.Response
import pf.WebCrypto
import pf.Io
import Q

E : [CryptoErr(Io.Thrown), BadSignature, Odd(Str)]

Pair : { private : WebCrypto.Key, public : WebCrypto.Key }

WebCryptoRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| {
		reply = |r| Response.from_text(200, show(r))
		data = Q.text(req, "data").to_utf8()
		match path {
			["agree", name] => reply(agree!(name))
			["ed25519"] => reply(ed25519!({}))
			["rsa_oaep"] => reply(rsa_oaep!({}))
			["aes"] => reply(aes!({}))
			["raw_roundtrip"] => reply(raw_roundtrip!({}))
			["generate_err"] => reply(generate_err!({}))
			["twins"] => reply(twins!({}))
			["sync"] => reply(sync!({}))
			# PLAN.md 8c, the measure: `n` hashes of `size` bytes in wasm (`bench/sha256-bench.mjs`).
			["sha256"] => Response.from_text(200, sha256_loop(Q.num(req, "size"), Q.num(req, "n")))
			# The registry cases (API.md RN6, RN9, RN18).
			["rs256_verify"] => reply(rs256_verify!(Q.text(req, "jwk"), from_hex(Q.text(req, "sig")), data))
			["rs256_verify_two"] => reply(rs256_verify_two!(Q.text(req, "jwk"), from_hex(Q.text(req, "sig")), data))
			["rs256_sign"] => reply(rs256_sign!(from_hex(Q.text(req, "pkcs8")), data))
			["jwk_import"] => reply(jwk_import!(Q.text(req, "priv"), Q.text(req, "pub"), data))
			["hmac"] => reply(hmac!(Q.text(req, "key").to_utf8(), data))
			# A key pinned by one request (`Io.pin!`), used by a later one (API.md RS2).
			["pin", name] => reply(pin!(name))
			["use", name] => reply(use!(name, data))
			_ => Response.from_text(404, "no route")
		}
	}
}

show : Try(Str, E) -> Str
show = |r| match r {
	Ok(s) => s
	Err(CryptoErr(t)) => "CryptoErr ${t.name}: ${t.message}"
	Err(BadSignature) => "BadSignature"
	Err(Odd(s)) => "Odd ${s}"
}

pair! : WebCrypto.KeyAlg => Try(Pair, E)
pair! = |alg| match WebCrypto.generate_key!(alg)? {
	Pair(p) => Ok(p)
	One(_) => Err(Odd("not a pair"))
}

## Two sides make a key pair each, and each derives the secret from its own private key and the public key of the other.
agree! : Str => Try(Str, E)
agree! = |name| {
	alg : WebCrypto.KeyAlg
	alg = match name {
		"p256" => Ecdh(P256)
		"p384" => Ecdh(P384)
		"p521" => Ecdh(P521)
		_ => X25519
	}
	derive = |theirs| match name {
		"p256" => Ecdh({ curve: P256, public: theirs })
		"p384" => Ecdh({ curve: P384, public: theirs })
		"p521" => Ecdh({ curve: P521, public: theirs })
		_ => X25519({ public: theirs })
	}
	a = pair!(alg)?
	b = pair!(alg)?
	c = pair!(alg)?
	x = WebCrypto.derive_bits!({ alg: derive(b.public), key: a.private, length_bits: 256 })?
	y = WebCrypto.derive_bits!({ alg: derive(a.public), key: b.private, length_bits: 256 })?
	z = WebCrypto.derive_bits!({ alg: derive(c.public), key: a.private, length_bits: 256 })?
	Ok("same=${Str.inspect(x == y)} bytes=${x.len().to_str()} third_differs=${Str.inspect(x != z)}")
}

## The signature of the private key verifies with the public key. A changed text does not.
ed25519! : {} => Try(Str, E)
ed25519! = |{}| {
	p = pair!(Ed25519)?
	text = "a message".to_utf8()
	signature = WebCrypto.sign!({ alg: Ed25519, key: p.private, data: text })?
	good = WebCrypto.verify!({ alg: Ed25519, key: p.public, signature, data: text })
	changed = WebCrypto.verify!({ alg: Ed25519, key: p.public, signature, data: "a messagf".to_utf8() })
	Ok("sig=${signature.len().to_str()} verify=${show_unit(good)} changed=${show_unit(changed)}")
}

show_unit : Try({}, [BadSignature, CryptoErr(Io.Thrown)]) -> Str
show_unit = |r| match r {
	Ok({}) => "Ok"
	Err(BadSignature) => "BadSignature"
	Err(CryptoErr(t)) => "CryptoErr ${t.name}"
}

rsa_oaep! : {} => Try(Str, E)
rsa_oaep! = |{}| {
	p = match WebCrypto.generate_key_with!(RsaOaep(Sha256), { modulus_bits: 2048 })? {
		Pair(keys) => keys
		One(_) => return Err(Odd("not a pair"))
	}
	text = "the secret of the day".to_utf8()
	cipher = RsaOaep({ label: "l".to_utf8(), hash: Sha256 })
	sealed = WebCrypto.encrypt!({ cipher, key: p.public, data: text })?
	opened = WebCrypto.decrypt!({ cipher, key: p.private, data: sealed })?
	Ok("cipher=${sealed.len().to_str()} same=${Str.inspect(opened == text)}")
}

## AES-GCM (the key of 256 and of 128 bits), AES-CBC and AES-CTR: encrypt, then decrypt.
aes! : {} => Try(Str, E)
aes! = |{}| {
	text = "the secret of the day".to_utf8()
	k256 = one!(WebCrypto.generate_key!(AesGcm)?)?
	k128 = one!(WebCrypto.generate_key_with!(AesGcm, { length_bits: 128 })?)?
	iv = WebCrypto.random!(12)
	gcm = AesGcm({ iv: iv })
	sealed = WebCrypto.encrypt!({ cipher: gcm, key: k256, data: text })?
	opened = WebCrypto.decrypt!({ cipher: gcm, key: k256, data: sealed })?
	sealed128 = WebCrypto.encrypt!({ cipher: gcm, key: k128, data: text })?
	opened128 = WebCrypto.decrypt!({ cipher: gcm, key: k128, data: sealed128 })?
	# A wrong key does not decrypt.
	wrong = WebCrypto.decrypt!({ cipher: gcm, key: k128, data: sealed })
	cbc_key = one!(WebCrypto.generate_key!(AesCbc)?)?
	cbc = AesCbc({ iv: WebCrypto.random!(16) })
	cbc_sealed = WebCrypto.encrypt!({ cipher: cbc, key: cbc_key, data: text })?
	cbc_opened = WebCrypto.decrypt!({ cipher: cbc, key: cbc_key, data: cbc_sealed })?
	ctr_key = one!(WebCrypto.generate_key!(AesCtr)?)?
	ctr = AesCtr({ counter: WebCrypto.random!(16), length_bits: 64 })
	ctr_sealed = WebCrypto.encrypt!({ cipher: ctr, key: ctr_key, data: text })?
	ctr_opened = WebCrypto.decrypt!({ cipher: ctr, key: ctr_key, data: ctr_sealed })?
	key_bytes = |k| match k {
		Raw(b) => b.len().to_str()
		_ => "?"
	}
	Ok(
		"gcm=${Str.inspect(opened == text)} cipher=${sealed.len().to_str()} gcm128=${Str.inspect(opened128 == text)} keys=${key_bytes(k256)},${key_bytes(k128)} wrong=${Str.inspect(wrong.is_err())} cbc=${Str.inspect(cbc_opened == text)} ctr=${Str.inspect(ctr_opened == text)}",
	)
}

one! : WebCrypto.Generated => Try(WebCrypto.Key, E)
one! = |g| match g {
	One(k) => Ok(k)
	Pair(_) => Err(Odd("not one key"))
}

## `export_key!` of an `import_key!` of `Raw(b)` is `Raw(b)`. The other forms and keys as data.
raw_roundtrip! : {} => Try(Str, E)
raw_roundtrip! = |{}| {
	b = WebCrypto.random!(32)
	aes = WebCrypto.import_key!(AesGcm, Raw(b))?
	raw = WebCrypto.export_key!(aes, Raw)?
	hmac = WebCrypto.import_key!(Hmac(Sha256), Raw(b))?
	jwk = match WebCrypto.export_key!(hmac, Jwk)? {
		Jwk(text) => text
		_ => ""
	}
	p = pair!(Ecdsa(P256))?
	pkcs8 = WebCrypto.export_key!(WebCrypto.import_key!(Ecdsa(P256), p.private)?, Pkcs8)?
	spki = WebCrypto.export_key!(WebCrypto.import_key!(Ecdsa(P256), p.public)?, Spki)?
	# A key as data gives its own form, and no other (it has no algorithm).
	same = WebCrypto.export_key!(Raw(b), Raw)
	other = WebCrypto.export_key!(Raw(b), Spki)
	Ok(
		"raw=${Str.inspect(raw == Raw(b))} jwk=${Str.inspect(jwk.contains("\"kty\":\"oct\""))} pkcs8=${Str.inspect(pkcs8 == p.private)} spki=${Str.inspect(spki == p.public)} data_same=${Str.inspect(same == Ok(Raw(b)))} data_other=${Str.inspect(other.is_err())}",
	)
}

## PBKDF2 and HKDF have no `generateKey`: `CryptoErr`.
generate_err! : {} => Try(Str, E)
generate_err! = |{}| match WebCrypto.generate_key!(Pbkdf2) {
	Ok(_) => Ok("Ok")
	Err(CryptoErr(t)) => Ok("CryptoErr ${t.name}: ${t.message}")
}

## Every function through its `Io` twin: one wait each (`calls=` is the number of them).
twins! : {} => Try(Str, E)
twins! = |{}| {
	hmac_key = one!(Io.run!(WebCrypto.generate_key(Hmac(Sha256)))?)?
	signature = Io.run!(WebCrypto.sign({ alg: Hmac(Sha256), key: hmac_key, data: "x".to_utf8() }))?
	Io.run!(WebCrypto.verify({ alg: Hmac(Sha256), key: hmac_key, signature, data: "x".to_utf8() }))?
	aes_key = one!(Io.run!(WebCrypto.generate_key_with(AesGcm, { length_bits: 128 }))?)?
	gcm = AesGcm({ iv: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12] })
	sealed = Io.run!(WebCrypto.encrypt({ cipher: gcm, key: aes_key, data: "xy".to_utf8() }))?
	opened = Io.run!(WebCrypto.decrypt({ cipher: gcm, key: aes_key, data: sealed }))?
	a = match Io.run!(WebCrypto.generate_key(X25519))? {
		Pair(p) => p
		One(_) => return Err(Odd("not a pair"))
	}
	b = match Io.run!(WebCrypto.generate_key(X25519))? {
		Pair(p) => p
		One(_) => return Err(Odd("not a pair"))
	}
	x = Io.run!(WebCrypto.derive_bits({ alg: X25519({ public: b.public }), key: a.private, length_bits: 256 }))?
	y = Io.run!(WebCrypto.derive_bits({ alg: X25519({ public: a.public }), key: b.private, length_bits: 256 }))?
	imported = Io.run!(WebCrypto.import_key(AesGcm, Raw(WebCrypto.random!(16))))?
	exported = Io.run!(WebCrypto.export_key(imported, Raw))?
	Ok("ok=${Str.inspect(opened == "xy".to_utf8() and x == y)} exported=${Str.inspect(exported != Raw([]))} calls=12")
}

## `timing_safe_equal!`, `random!` and `random_uuid!`: `call!`, no wait.
sync! : {} => Try(Str, E)
sync! = |{}| {
	a = WebCrypto.random!(16)
	b = WebCrypto.random!(16)
	big = WebCrypto.random!(100_000)
	Ok(
		"equal=${Str.inspect(WebCrypto.timing_safe_equal!(a, a.map(|x| x)))} differ=${Str.inspect(WebCrypto.timing_safe_equal!(a, b))} short=${Str.inspect(WebCrypto.timing_safe_equal!([1, 2], [1, 2, 3]))} random=${a.len().to_str()} big=${big.len().to_str()} distinct=${Str.inspect(a != b)} uuid=${WebCrypto.random_uuid!({})}",
	)
}

# RN6: the RS256 signature of a JWT with the public key as a JWK, in one crossing (the import and the verify).
rs256_verify! : Str, List(U8), List(U8) => Try(Str, E)
rs256_verify! = |jwk, signature, data| Ok(show_unit(WebCrypto.verify!({ alg: RsaPkcs1(Sha256), key: Jwk(jwk), signature, data })))

## The control of `rs256_verify!`: `import_key!`, then `verify!` with the `Imported` key: two waits.
rs256_verify_two! : Str, List(U8), List(U8) => Try(Str, E)
rs256_verify_two! = |jwk, signature, data| {
	key = WebCrypto.import_key!(RsaPkcs1(Sha256), Jwk(jwk))?
	Ok(show_unit(WebCrypto.verify!({ alg: RsaPkcs1(Sha256), key, signature, data })))
}

# RN9, RN18: the RS256 signature of the App JWT with a PKCS#8 key. The answer is the signature in hex.
rs256_sign! : List(U8), List(U8) => Try(Str, E)
rs256_sign! = |pkcs8, data| {
	signature = WebCrypto.sign!({ alg: RsaPkcs1(Sha256), key: Pkcs8(pkcs8), data })?
	Ok(to_hex(signature))
}

## A JWK of a private key signs and a JWK of a public key verifies (`import_key!` picks the usages from the `d` member).
jwk_import! : Str, Str, List(U8) => Try(Str, E)
jwk_import! = |priv, pub, data| {
	private = WebCrypto.import_key!(RsaPkcs1(Sha256), Jwk(priv))?
	public = WebCrypto.import_key!(RsaPkcs1(Sha256), Jwk(pub))?
	signature = WebCrypto.sign!({ alg: RsaPkcs1(Sha256), key: private, data })?
	good = WebCrypto.verify!({ alg: RsaPkcs1(Sha256), key: public, signature, data })
	Ok("verify=${show_unit(good)} sig=${to_hex(signature)}")
}

# RN9: HMAC-SHA256 of the raw body. `WebCrypto.sign!` and `hmac_sha256` (Roc) give the same bytes.
hmac! : List(U8), List(U8) => Try(Str, E)
hmac! = |key, data| {
	signature = WebCrypto.sign!({ alg: Hmac(Sha256), key: Raw(key), data })?
	roc = WebCrypto.hmac_sha256(key, data)
	good = WebCrypto.verify!({ alg: Hmac(Sha256), key: Raw(key), signature, data })
	changed = WebCrypto.verify!({ alg: Hmac(Sha256), key: Raw(key), signature, data: data.append(0) })
	Ok("sign=${to_hex(signature)} roc=${to_hex(roc)} same=${Str.inspect(WebCrypto.timing_safe_equal!(signature, roc))} verify=${show_unit(good)} changed=${show_unit(changed)}")
}

## RS2: the key of `import_key!` is a ref of this request. `Io.pin!` keeps the `CryptoKey` for a later request.
pin! : Str => Try(Str, E)
pin! = |name| {
	key = match WebCrypto.import_key!(Hmac(Sha256), Raw("pin-secret".to_utf8()))? {
		Imported(ref) => ref
		_ => return Err(Odd("not imported"))
	}
	match Io.pin!(name, Ref(key), { max_age_ms: 600_000 }) {
		Ok({}) => Ok("pinned")
		Err(PinErr(t)) => Err(CryptoErr(t))
	}
}

## A later request gets the key with `Io.pinned!` (a new ref of this request), and signs and verifies with it.
use! : Str, List(U8) => Try(Str, E)
use! = |name, data| {
	key = match Io.pinned!(name) {
		Ok(Ref(ref)) => Imported(ref)
		Ok(other) => return Err(Odd("pinned gave ${Str.inspect(other)}"))
		Err(NotPinned) => return Err(Odd("NotPinned"))
	}
	signature = WebCrypto.sign!({ alg: Hmac(Sha256), key, data })?
	good = WebCrypto.verify!({ alg: Hmac(Sha256), key, signature, data })
	Ok("sig=${to_hex(signature)} verify=${show_unit(good)} roc=${to_hex(WebCrypto.hmac_sha256("pin-secret".to_utf8(), data))}")
}

## `n` times `Crypto.SHA256.hash` of a buffer of `size` bytes (the first byte is the count, so no hash is the same as the one
## before). Gives the hex of the last digest.
sha256_loop : U64, U64 -> Str
sha256_loop = |size, n| {
	var $data = List.repeat(7, size)
	var $last = Crypto.SHA256.hash([])
	var $i = 0
	while $i < n {
		match $data.set(0, $i.to_u8_wrap()) {
			Ok(next) => {
				$data = next
			}
			Err(_) => {}
		}
		$last = Crypto.SHA256.hash($data)
		$i = $i + 1
	}
	if n == 0 "" else $last.to_hex()
}

to_hex : List(U8) -> Str
to_hex = |bytes| {
	digit = |n| if n < 10 48 + n else 87 + n
	chars = bytes.join_map(|b| [digit(b // 16), digit(b % 16)])
	Str.from_utf8(chars) ?? ""
}

from_hex : Str -> List(U8)
from_hex = |text| {
	nibble = |c| if c >= 97 c - 87 else c - 48
	text.to_utf8().chunks_of(2).map(
		|pair| match pair {
			[hi, lo] => nibble(hi) * 16 + nibble(lo)
			_ => 0
		},
	)
}
