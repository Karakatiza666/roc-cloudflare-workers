## WebCrypto (MODULES.md 10): `crypto.subtle`, `getRandomValues`, `randomUUID` and `subtle.timingSafeEqual`. Not
## `Crypto`: that name is a builtin module of Roc. A key is its material (MC13), and each function runs `importKey` and
## its operation in one program: one crossing and one wait. `Imported` is a ref of the task (`import_key!`), for many
## operations in one task. Each `crypto.subtle` method gives a promise, so those functions wait once (`Io.new`, `await!`).
## `timing_safe_equal!`, `random!` and `random_uuid!` give no promise: one `call!`, no wait.
import Io
import Js

WebCrypto :: [].{

	## `subtle.sign`. `key` is data (`Raw`, `Pkcs8`, `Jwk`) or `Imported`.
	sign : { alg : WebCrypto.Alg, key : WebCrypto.Key, data : List(U8) } -> Io(List(U8), [CryptoErr(Io.Thrown)])
	sign = |a| {
		(ops, key) = with_key(a.key, import_algo(a.alg), ["sign"], Bool.False, [])
		Io.new(ops.append(Call(Slot(1), "sign", [Lit(sign_algo(a.alg)), arg_of(key), Lit(Bytes(a.data))])), bytes_read)
	}

	sign! : { alg : WebCrypto.Alg, key : WebCrypto.Key, data : List(U8) } => Try(List(U8), [CryptoErr(Io.Thrown)])
	sign! = |a| Io.run!(sign(a))

	## `subtle.verify`. A signature that does not match is `BadSignature`.
	verify : { alg : WebCrypto.Alg, key : WebCrypto.Key, signature : List(U8), data : List(U8) } -> Io({}, [BadSignature, CryptoErr(Io.Thrown)])
	verify = |a| {
		(ops, key) = with_key(a.key, import_algo(a.alg), ["verify"], Bool.False, [])
		Io.new(
			ops.append(Call(Slot(1), "verify", [Lit(sign_algo(a.alg)), arg_of(key), Lit(Bytes(a.signature)), Lit(Bytes(a.data))])),
			|r| match r {
				Ok(Bool(ok)) => if ok Ok({}) else Err(BadSignature)
				Ok(other) => Err(CryptoErr(bad_data("verify gave ${Str.inspect(other)}")))
				Err(t) => Err(CryptoErr(t))
			},
		)
	}

	verify! : { alg : WebCrypto.Alg, key : WebCrypto.Key, signature : List(U8), data : List(U8) } => Try({}, [BadSignature, CryptoErr(Io.Thrown)])
	verify! = |a| Io.run!(verify(a))

	## `subtle.encrypt`. `RsaOaep` takes a public key (`Spki`), the AES ciphers the one key.
	encrypt : { cipher : WebCrypto.Cipher, key : WebCrypto.Key, data : List(U8) } -> Io(List(U8), [CryptoErr(Io.Thrown)])
	encrypt = |a| {
		(ops, key) = with_key(a.key, cipher_import_algo(a.cipher), ["encrypt"], Bool.False, [])
		Io.new(ops.append(Call(Slot(1), "encrypt", [Lit(cipher_algo(a.cipher)), arg_of(key), Lit(Bytes(a.data))])), bytes_read)
	}

	encrypt! : { cipher : WebCrypto.Cipher, key : WebCrypto.Key, data : List(U8) } => Try(List(U8), [CryptoErr(Io.Thrown)])
	encrypt! = |a| Io.run!(encrypt(a))

	## `subtle.decrypt`. `RsaOaep` takes a private key (`Pkcs8`).
	decrypt : { cipher : WebCrypto.Cipher, key : WebCrypto.Key, data : List(U8) } -> Io(List(U8), [CryptoErr(Io.Thrown)])
	decrypt = |a| {
		(ops, key) = with_key(a.key, cipher_import_algo(a.cipher), ["decrypt"], Bool.False, [])
		Io.new(ops.append(Call(Slot(1), "decrypt", [Lit(cipher_algo(a.cipher)), arg_of(key), Lit(Bytes(a.data))])), bytes_read)
	}

	decrypt! : { cipher : WebCrypto.Cipher, key : WebCrypto.Key, data : List(U8) } => Try(List(U8), [CryptoErr(Io.Thrown)])
	decrypt! = |a| Io.run!(decrypt(a))

	## `subtle.deriveBits`. `length_bits` is in bits (MC10). For `Ecdh` and `X25519`, `key` is the private key of the app
	## and `public` the public key of the peer (both imported in the same program).
	derive_bits : { alg : WebCrypto.Derive, key : WebCrypto.Key, length_bits : U32 } -> Io(List(U8), [CryptoErr(Io.Thrown)])
	derive_bits = |a| {
		(ops, key) = with_key(a.key, derive_import_algo(a.alg), ["deriveBits"], Bool.False, [])
		(ops2, algo) = match a.alg {
			Ecdh({ curve, public }) => with_peer(ops, public, "ECDH", Obj([("name", Text("ECDH")), ("namedCurve", Text(curve_name(curve)))]))
			X25519({ public }) => with_peer(ops, public, "X25519", Obj([("name", Text("X25519"))]))
			other => (ops, Lit(derive_algo(other)))
		}
		Io.new(ops2.append(Call(Slot(1), "deriveBits", [algo, arg_of(key), Lit(Int(a.length_bits.to_i64()))])), bytes_read)
	}

	derive_bits! : { alg : WebCrypto.Derive, key : WebCrypto.Key, length_bits : U32 } => Try(List(U8), [CryptoErr(Io.Thrown)])
	derive_bits! = |a| Io.run!(derive_bits(a))

	## `subtle.importKey` with `extractable: true`: an `Imported` key, for many operations in one task. The usages follow
	## the algorithm and the form of the key (a private key signs, a public key verifies).
	import_key : WebCrypto.KeyAlg, WebCrypto.Key -> Io(WebCrypto.Key, [CryptoErr(Io.Thrown)])
	import_key = |alg, key| {
		(ops, at) = with_key(key, import_key_algo(alg), import_usages(alg, key), Bool.True, [])
		Io.new(
			ops.append(Keep(at)),
			|r| match r {
				Ok(Ref(ref)) => Ok(Imported(ref))
				Ok(other) => Err(CryptoErr(bad_data("importKey gave ${Str.inspect(other)}")))
				Err(t) => Err(CryptoErr(t))
			},
		)
	}

	import_key! : WebCrypto.KeyAlg, WebCrypto.Key => Try(WebCrypto.Key, [CryptoErr(Io.Thrown)])
	import_key! = |alg, key| Io.run!(import_key(alg, key))

	## `subtle.exportKey` of an `Imported` key as data: `Raw`, `Pkcs8`, `Spki` or `Jwk` (the JSON text). A key that is
	## data already has no algorithm, so it can only give its own form (no crossing): another form is `CryptoErr`.
	export_key : WebCrypto.Key, [Raw, Pkcs8, Spki, Jwk] -> Io(WebCrypto.Key, [CryptoErr(Io.Thrown)])
	export_key = |key, form| match key {
		Imported(ref) => {
			ops = [
				Get(Root("global"), "crypto"),
				Get(Slot(0), "subtle"),
				Call(Slot(1), "exportKey", [Lit(Text(form_name(form))), Lit(Ref(ref))]),
			]
			with_json = match form {
				Jwk => ops.concat([Get(Root("global"), "JSON"), Call(Slot(3), "stringify", [Slot(2)])])
				_ => ops
			}
			Io.new(
				with_json,
				|r| match (r, form) {
					(Ok(Bytes(b)), Raw) => Ok(Raw(b))
					(Ok(Bytes(b)), Pkcs8) => Ok(Pkcs8(b))
					(Ok(Bytes(b)), Spki) => Ok(Spki(b))
					(Ok(Text(s)), Jwk) => Ok(Jwk(s))
					(Ok(other), _) => Err(CryptoErr(bad_data("exportKey gave ${Str.inspect(other)}")))
					(Err(t), _) => Err(CryptoErr(t))
				},
			)
		}
		_ => match (key, form) {
			(Raw(_), Raw) | (Pkcs8(_), Pkcs8) | (Spki(_), Spki) | (Jwk(_), Jwk) => Io.sync([], |_| Ok(key))
			_ => Io.sync([], |_| Err(CryptoErr(bad_data("export_key!: a key as data has no algorithm: import_key! it first"))))
		}
	}

	export_key! : WebCrypto.Key, [Raw, Pkcs8, Spki, Jwk] => Try(WebCrypto.Key, [CryptoErr(Io.Thrown)])
	export_key! = |key, form| Io.run!(export_key(key, form))

	## `subtle.generateKey` with `extractable: true`, then `exportKey` of each key, in one program: the key is data
	## (`One(Raw)` for an AES or HMAC key, `Pair({ private: Pkcs8, public: Spki })` for the others).
	generate_key : WebCrypto.KeyAlg -> Io(WebCrypto.Generated, [CryptoErr(Io.Thrown)])
	generate_key = |alg| generate_key_with(alg, {})

	generate_key! : WebCrypto.KeyAlg => Try(WebCrypto.Generated, [CryptoErr(Io.Thrown)])
	generate_key! = |alg| Io.run!(generate_key(alg))

	## `modulus_bits`: RSA (default 2048, the public exponent is 65537). `length_bits`: AES (default 256) and HMAC (default:
	## the block size of the hash). PBKDF2 and HKDF have no `generateKey`: `CryptoErr`.
	generate_key_with : WebCrypto.KeyAlg, { modulus_bits ?: U32, length_bits ?: U32 } -> Io(WebCrypto.Generated, [CryptoErr(Io.Thrown)])
	generate_key_with = |alg, opts| {
		gen = Call(Slot(1), "generateKey", [Lit(generate_algo(alg, opts.?modulus_bits ?? 2048, opts.?length_bits)), Lit(Bool(Bool.True)), Lit(generate_usages(alg))])
		prelude = [Get(Root("global"), "crypto"), Get(Slot(0), "subtle"), gen]
		if is_pair(alg) {
			Io.new(
				prelude.concat([
					Get(Slot(2), "privateKey"),
					Get(Slot(2), "publicKey"),
					Call(Slot(1), "exportKey", [Lit(Text("pkcs8")), Slot(3)]),
					Call(Slot(1), "exportKey", [Lit(Text("spki")), Slot(4)]),
					Record([("private", Slot(5)), ("public", Slot(6))]),
				]),
				|r| match r {
					Ok(Obj([("private", Bytes(p)), ("public", Bytes(q))])) => Ok(Pair({ private: Pkcs8(p), public: Spki(q) }))
					Ok(other) => Err(CryptoErr(bad_data("generateKey gave ${Str.inspect(other)}")))
					Err(t) => Err(CryptoErr(t))
				},
			)
		} else {
			Io.new(
				prelude.append(Call(Slot(1), "exportKey", [Lit(Text("raw")), Slot(2)])),
				|r| match r {
					Ok(Bytes(b)) => Ok(One(Raw(b)))
					Ok(other) => Err(CryptoErr(bad_data("generateKey gave ${Str.inspect(other)}")))
					Err(t) => Err(CryptoErr(t))
				},
			)
		}
	}

	generate_key_with! : WebCrypto.KeyAlg, { modulus_bits ?: U32, length_bits ?: U32 } => Try(WebCrypto.Generated, [CryptoErr(Io.Thrown)])
	generate_key_with! = |alg, opts| Io.run!(generate_key_with(alg, opts))

	## HMAC-SHA256 in Roc over the builtin SHA-256 (RFC 2104): no crossing, no wait (RN9: the webhook signature).
	hmac_sha256 : List(U8), List(U8) -> List(U8)
	hmac_sha256 = |key, msg| {
		block = 64
		k0 = if key.len() > block Crypto.SHA256.hash(key).to_bytes() else key
		k = k0.concat(List.repeat(0, block - k0.len()))
		inner = Crypto.SHA256.hash(k.map(|b| b.bitwise_xor(0x36)).concat(msg)).to_bytes()
		Crypto.SHA256.hash(k.map(|b| b.bitwise_xor(0x5c)).concat(inner)).to_bytes()
	}

	## SHA-256 of bytes in wasm memory: the builtin `Crypto.SHA256` below `sha256_crossover_bytes` (no crossing), else
	## `crypto.subtle.digest` (one crossing, one wait, the isolate runs other tasks meanwhile). The result is the 32 bytes of
	## the digest. For a body that is not in wasm memory yet, use `Body.sha256!`.
	sha256! : List(U8) => Try(List(U8), [CryptoErr(Io.Thrown)])
	sha256! = |bytes|
		if use_builtin(bytes) {
			Ok(Crypto.SHA256.hash(bytes).to_bytes())
		} else {
			Io.run!(digest_io(bytes))
		}

	## The twin of `sha256!` (MC3). Below the crossover its program has no op: a `Io.run!` of it is one `call!` of an
	## empty program, and inside `Io.both!` it is a branch with no op.
	sha256 : List(U8) -> Io(List(U8), [CryptoErr(Io.Thrown)])
	sha256 = |bytes|
		if use_builtin(bytes) {
			Io.sync([], |_| Ok(Crypto.SHA256.hash(bytes).to_bytes()))
		} else {
			digest_io(bytes)
		}

	## `crypto.subtle.timingSafeEqual`: one `call!`, no wait. Texts of different lengths are not equal (no crossing).
	timing_safe_equal! : List(U8), List(U8) => Bool
	timing_safe_equal! = |a, b|
		if a.len() != b.len() {
			Bool.False
		} else {
			match Io.call!([Get(Root("global"), "crypto"), Get(Slot(0), "subtle"), Call(Slot(1), "timingSafeEqual", [Lit(Bytes(a)), Lit(Bytes(b))])]) {
				Ok(Bool(same)) => same
				_ => Bool.False
			}
		}

	## `crypto.getRandomValues`: `n` new random bytes, one `call!` for each 65,536 bytes (the limit of Workers).
	random! : U64 => List(U8)
	random! = |n| {
		chunk = if n > 65_536 65_536 else n
		got = match Io.call!([Get(Root("global"), "crypto"), New(Root("global"), "Uint8Array", [Lit(Int(chunk.to_i64_wrap()))]), Call(Slot(0), "getRandomValues", [Slot(1)])]) {
			Ok(Bytes(b)) => b
			Ok(other) => crash "WebCrypto.random!: getRandomValues gave ${Str.inspect(other)}"
			Err(t) => crash "WebCrypto.random!: ${t.name}: ${t.message}"
		}
		if n > chunk got.concat(WebCrypto.random!(n - chunk)) else got
	}

	## `crypto.randomUUID`: one `call!`, no wait.
	random_uuid! : {} => Str
	random_uuid! = |{}| match Io.call!([Get(Root("global"), "crypto"), Call(Slot(0), "randomUUID", [])]) {
		Ok(Text(s)) => s
		Ok(other) => crash "WebCrypto.random_uuid!: randomUUID gave ${Str.inspect(other)}"
		Err(t) => crash "WebCrypto.random_uuid!: ${t.name}: ${t.message}"
	}

	## The material of a key, or a ref of the task (`import_key!`, MC13).
	Key : [Jwk(Str), Raw(List(U8)), Pkcs8(List(U8)), Spki(List(U8)), Imported(Js.Ref)]

	Generated : [One(WebCrypto.Key), Pair({ private : WebCrypto.Key, public : WebCrypto.Key })]

	Alg : [Hmac(WebCrypto.Hash), RsaPkcs1(WebCrypto.Hash), RsaPss({ hash : WebCrypto.Hash, salt_length_bytes : U32 }), Ecdsa(WebCrypto.Curve, WebCrypto.Hash), Ed25519]

	## `RsaOaep` has a `hash`: `importKey` of an RSA-OAEP key needs one, and a key as data has none (MODULES.md 10).
	Cipher : [AesGcm({ iv : List(U8) }), AesCbc({ iv : List(U8) }), AesCtr({ counter : List(U8), length_bits : U32 }), RsaOaep({ label : List(U8), hash : WebCrypto.Hash })]

	Derive : [Pbkdf2({ salt : List(U8), iterations : U32, hash : WebCrypto.Hash }), Hkdf({ salt : List(U8), info : List(U8), hash : WebCrypto.Hash }), Ecdh({ curve : WebCrypto.Curve, public : WebCrypto.Key }), X25519({ public : WebCrypto.Key })]

	KeyAlg : [Hmac(WebCrypto.Hash), RsaPkcs1(WebCrypto.Hash), RsaPss(WebCrypto.Hash), RsaOaep(WebCrypto.Hash), Ecdsa(WebCrypto.Curve), Ecdh(WebCrypto.Curve), Ed25519, X25519, AesGcm, AesCbc, AesCtr, Pbkdf2, Hkdf]

	Hash : [Sha256, Sha384, Sha512]

	Curve : [P256, P384, P521]
}

## The ops of a program that has the key: `crypto` (slot 0), `subtle` (slot 1), then the import of `key` (none for an
## `Imported` key). Gives all ops, and where the key is. `before`: the ops of the program already (a second key goes
## after the first): empty for the first key.
with_key : WebCrypto.Key, Js, List(Str), Bool, List(Js.Op) -> (List(Js.Op), Js.Target)
with_key = |key, algo, usages, extractable, before| {
	base = if before.is_empty() [Get(Root("global"), "crypto"), Get(Slot(0), "subtle")] else before
	n = base.len().to_u32_wrap()
	args = |format, material| [Lit(Text(format)), material, Lit(algo), Lit(Bool(extractable)), Lit(Arr(usages.map(|u| Text(u))))]
	match key {
		Imported(ref) => (base, Ref(ref))
		Raw(b) => (base.append(Call(Slot(1), "importKey", args("raw", Lit(Bytes(b))))), Slot(n))
		Pkcs8(b) => (base.append(Call(Slot(1), "importKey", args("pkcs8", Lit(Bytes(b))))), Slot(n))
		Spki(b) => (base.append(Call(Slot(1), "importKey", args("spki", Lit(Bytes(b))))), Slot(n))
		Jwk(text) => {
			ops = base.concat([Get(Root("global"), "JSON"), Call(Slot(n), "parse", [Lit(Text(text))])])
			(ops.append(Call(Slot(1), "importKey", args("jwk", Slot(n + 1)))), Slot(n + 2))
		}
	}
}

## The public key of the peer of `Ecdh` and `X25519`, imported after the key of the app, and the algorithm object
## `{ name, public }` (a `Record` op, because it holds a key).
with_peer : List(Js.Op), WebCrypto.Key, Str, Js -> (List(Js.Op), Js.Arg)
with_peer = |ops, public, name, import_algo_js| {
	(with_pub, pub) = with_key(public, import_algo_js, [], Bool.False, ops)
	at = with_pub.len().to_u32_wrap()
	(with_pub.append(Record([("name", Lit(Text(name))), ("public", arg_of(pub))])), Slot(at))
}

arg_of : Js.Target -> Js.Arg
arg_of = |t| match t {
	Slot(n) => Slot(n)
	Ref(r) => Lit(Ref(r))
	Root(_) => crash "WebCrypto: a key is never a root"
}

bad_data : Str -> Io.Thrown
bad_data = |message| { name: "BadData", message }

## The size from which `crypto.subtle.digest` is faster than the builtin SHA-256 in workerd: 2.7 KB, measured with the
## copy of the bytes out of wasm memory and the wait (PLAN.md 8g, bench/README.md "Step 8g"; Node: 6 KB). At 2.3 to
## 4 KB the two cost about the same, so the measured point is used. The edge value is on the PLAN.md 11c list.
sha256_crossover_bytes : U64
sha256_crossover_bytes = 2_700

use_builtin : List(U8) -> Bool
use_builtin = |bytes| bytes.len() < sha256_crossover_bytes

## `crypto.subtle.digest('SHA-256', bytes)`: the bytes cross once, the digest comes back as an `ArrayBuffer`.
digest_io : List(U8) -> Io(List(U8), [CryptoErr(Io.Thrown)])
digest_io = |bytes| Io.new(
	[Get(Root("global"), "crypto"), Get(Slot(0), "subtle"), Call(Slot(1), "digest", [Lit(Text("SHA-256")), Lit(Bytes(bytes))])],
	bytes_read,
)

## The result of a function that gives bytes (an `ArrayBuffer` is `Bytes`, J rules).
bytes_read : Try(Js, Io.Thrown) -> Try(List(U8), [CryptoErr(Io.Thrown)])
bytes_read = |r| match r {
	Ok(Bytes(b)) => Ok(b)
	Ok(other) => Err(CryptoErr(bad_data("the result is ${Str.inspect(other)}, not bytes")))
	Err(t) => Err(CryptoErr(t))
}

named : Str -> Js
named = |name| Obj([("name", Text(name))])

hash_name : WebCrypto.Hash -> Str
hash_name = |h| match h {
	Sha256 => "SHA-256"
	Sha384 => "SHA-384"
	Sha512 => "SHA-512"
}

curve_name : WebCrypto.Curve -> Str
curve_name = |c| match c {
	P256 => "P-256"
	P384 => "P-384"
	P521 => "P-521"
}

## `{ name, hash }` or `{ name, namedCurve }`: the algorithm object of `importKey` and `generateKey`.
with_hash : Str, WebCrypto.Hash -> Js
with_hash = |name, h| Obj([("name", Text(name)), ("hash", Text(hash_name(h)))])

with_curve : Str, WebCrypto.Curve -> Js
with_curve = |name, c| Obj([("name", Text(name)), ("namedCurve", Text(curve_name(c)))])

## The algorithm of `sign` and `verify`.
sign_algo : WebCrypto.Alg -> Js
sign_algo = |alg| match alg {
	Hmac(_) => named("HMAC")
	RsaPkcs1(_) => named("RSASSA-PKCS1-v1_5")
	RsaPss({ salt_length_bytes, hash: _ }) => Obj([("name", Text("RSA-PSS")), ("saltLength", Int(salt_length_bytes.to_i64()))])
	Ecdsa(_, h) => Obj([("name", Text("ECDSA")), ("hash", Text(hash_name(h)))])
	Ed25519 => named("Ed25519")
}

## The algorithm of `importKey` for a key that signs or verifies.
import_algo : WebCrypto.Alg -> Js
import_algo = |alg| match alg {
	Hmac(h) => with_hash("HMAC", h)
	RsaPkcs1(h) => with_hash("RSASSA-PKCS1-v1_5", h)
	RsaPss({ hash, salt_length_bytes: _ }) => with_hash("RSA-PSS", hash)
	Ecdsa(c, _) => with_curve("ECDSA", c)
	Ed25519 => named("Ed25519")
}

cipher_algo : WebCrypto.Cipher -> Js
cipher_algo = |c| match c {
	AesGcm({ iv }) => Obj([("name", Text("AES-GCM")), ("iv", Bytes(iv))])
	AesCbc({ iv }) => Obj([("name", Text("AES-CBC")), ("iv", Bytes(iv))])
	AesCtr({ counter, length_bits }) => Obj([("name", Text("AES-CTR")), ("counter", Bytes(counter)), ("length", Int(length_bits.to_i64()))])
	RsaOaep({ label, hash: _ }) => Obj([("name", Text("RSA-OAEP")), ("label", Bytes(label))])
}

cipher_import_algo : WebCrypto.Cipher -> Js
cipher_import_algo = |c| match c {
	AesGcm(_) => named("AES-GCM")
	AesCbc(_) => named("AES-CBC")
	AesCtr(_) => named("AES-CTR")
	RsaOaep({ hash, label: _ }) => with_hash("RSA-OAEP", hash)
}

## The algorithm object of `deriveBits` for the kinds with no peer key (`Ecdh` and `X25519` are in `derive_bits`).
derive_algo : WebCrypto.Derive -> Js
derive_algo = |d| match d {
	Pbkdf2({ salt, iterations, hash }) => Obj([("name", Text("PBKDF2")), ("salt", Bytes(salt)), ("iterations", Int(iterations.to_i64())), ("hash", Text(hash_name(hash)))])
	Hkdf({ salt, info, hash }) => Obj([("name", Text("HKDF")), ("salt", Bytes(salt)), ("info", Bytes(info)), ("hash", Text(hash_name(hash)))])
	Ecdh(_) => crash "WebCrypto: Ecdh has a peer key"
	X25519(_) => crash "WebCrypto: X25519 has a peer key"
}

## The algorithm of `importKey` for the key of the app in `deriveBits`.
derive_import_algo : WebCrypto.Derive -> Js
derive_import_algo = |d| match d {
	Pbkdf2(_) => named("PBKDF2")
	Hkdf(_) => named("HKDF")
	Ecdh({ curve, public: _ }) => with_curve("ECDH", curve)
	X25519(_) => named("X25519")
}

## The algorithm object of `import_key!`.
import_key_algo : WebCrypto.KeyAlg -> Js
import_key_algo = |alg| match alg {
	Hmac(h) => with_hash("HMAC", h)
	RsaPkcs1(h) => with_hash("RSASSA-PKCS1-v1_5", h)
	RsaPss(h) => with_hash("RSA-PSS", h)
	RsaOaep(h) => with_hash("RSA-OAEP", h)
	Ecdsa(c) => with_curve("ECDSA", c)
	Ecdh(c) => with_curve("ECDH", c)
	Ed25519 => named("Ed25519")
	X25519 => named("X25519")
	AesGcm => named("AES-GCM")
	AesCbc => named("AES-CBC")
	AesCtr => named("AES-CTR")
	Pbkdf2 => named("PBKDF2")
	Hkdf => named("HKDF")
}

## The usages of `import_key!`: a private key signs, decrypts or derives, a public key verifies or encrypts (a public
## ECDH or X25519 key has no usage).
import_usages : WebCrypto.KeyAlg, WebCrypto.Key -> List(Str)
import_usages = |alg, key| match alg {
	Hmac(_) => ["sign", "verify"]
	AesGcm | AesCbc | AesCtr => ["encrypt", "decrypt"]
	Pbkdf2 | Hkdf => ["deriveBits"]
	RsaPkcs1(_) | RsaPss(_) | Ecdsa(_) | Ed25519 => if is_private(key) ["sign"] else ["verify"]
	RsaOaep(_) => if is_private(key) ["decrypt"] else ["encrypt"]
	Ecdh(_) | X25519 => if is_private(key) ["deriveBits"] else []
}

## A key as data is private when it is `Pkcs8`, or a JWK with the member `d`. `Raw` is a public key or a secret key.
is_private : WebCrypto.Key -> Bool
is_private = |key| match key {
	Pkcs8(_) => Bool.True
	Jwk(text) => {
		parsed : Try({ d : Str }, _)
		parsed = Json.parse(text)
		parsed.is_ok()
	}
	_ => Bool.False
}

generate_algo : WebCrypto.KeyAlg, U32, Try(U32, [MissingField]) -> Js
generate_algo = |alg, modulus_bits, length_bits| {
	rsa = |name, h| Obj([("name", Text(name)), ("hash", Text(hash_name(h))), ("modulusLength", Int(modulus_bits.to_i64())), ("publicExponent", Bytes([1, 0, 1]))])
	aes = |name| Obj([("name", Text(name)), ("length", Int((length_bits ?? 256).to_i64()))])
	match alg {
		Hmac(h) => match length_bits {
			Ok(n) => Obj([("name", Text("HMAC")), ("hash", Text(hash_name(h))), ("length", Int(n.to_i64()))])
			Err(_) => with_hash("HMAC", h)
		}
		RsaPkcs1(h) => rsa("RSASSA-PKCS1-v1_5", h)
		RsaPss(h) => rsa("RSA-PSS", h)
		RsaOaep(h) => rsa("RSA-OAEP", h)
		Ecdsa(c) => with_curve("ECDSA", c)
		Ecdh(c) => with_curve("ECDH", c)
		Ed25519 => named("Ed25519")
		X25519 => named("X25519")
		AesGcm => aes("AES-GCM")
		AesCbc => aes("AES-CBC")
		AesCtr => aes("AES-CTR")
		Pbkdf2 => named("PBKDF2")
		Hkdf => named("HKDF")
	}
}

generate_usages : WebCrypto.KeyAlg -> Js
generate_usages = |alg| Arr(
	match alg {
		Hmac(_) | RsaPkcs1(_) | RsaPss(_) | Ecdsa(_) | Ed25519 => [Text("sign"), Text("verify")]
		RsaOaep(_) | AesGcm | AesCbc | AesCtr => [Text("encrypt"), Text("decrypt")]
		Ecdh(_) | X25519 | Pbkdf2 | Hkdf => [Text("deriveBits")]
	},
)

## An asymmetric key is a pair: `generateKey` gives a `CryptoKeyPair`.
is_pair : WebCrypto.KeyAlg -> Bool
is_pair = |alg| match alg {
	RsaPkcs1(_) | RsaPss(_) | RsaOaep(_) | Ecdsa(_) | Ecdh(_) | Ed25519 | X25519 => Bool.True
	Hmac(_) | AesGcm | AesCbc | AesCtr | Pbkdf2 | Hkdf => Bool.False
}

form_name : [Raw, Pkcs8, Spki, Jwk] -> Str
form_name = |form| match form {
	Raw => "raw"
	Pkcs8 => "pkcs8"
	Spki => "spki"
	Jwk => "jwk"
}

# RFC 4231, test cases 1, 2 and 6 (a key longer than the block): no crossing, so `roc test` runs them.
hex : List(U8) -> Str
hex = |bytes| match Crypto.SHA256.Digest.from_bytes(bytes) {
	Ok(d) => d.to_hex()
	Err(_) => "not 32 bytes"
}

expect hex(WebCrypto.hmac_sha256(List.repeat(0x0b, 20), "Hi There".to_utf8())) == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
expect hex(WebCrypto.hmac_sha256("Jefe".to_utf8(), "what do ya want for nothing?".to_utf8())) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
expect hex(WebCrypto.hmac_sha256(List.repeat(0xaa, 131), "Test Using Larger Than Block-Size Key - Hash Key First".to_utf8())) == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"

# MODULES.md 10: the builtin below 2,700 bytes, `digest` from 2,700 bytes.
expect use_builtin(List.repeat(0, 0))
expect use_builtin(List.repeat(0, 2_699))
expect !use_builtin(List.repeat(0, 2_700))
expect !use_builtin(List.repeat(0, 1_048_576))
