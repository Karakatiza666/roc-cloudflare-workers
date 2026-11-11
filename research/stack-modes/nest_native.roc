app [main!] { cbor: "https://github.com/Karakatiza666/roc-cbor/releases/download/0.5.0/B5U2mPsWTtuxfCRMzqQxio2ecDv7CAzCoyEMENMh4FNF.tar.zst" }
import cbor.Cbor

Nest := [Leaf(I64), Node(Nest)].{
	is_eq : _
	encoder_for : _
	parser_for : _
}

build : U64 -> Nest
build = |n| if n == 0 Nest.Leaf(7) else Nest.Node(build(n - 1))

main! = |_args| {
	v = build(50)
	raw = Cbor.encode(v)
	back : Try(Nest, _)
	back = Cbor.parse(raw)
	echo!("len=${raw.len().to_str()} same=${Str.inspect(back == Ok(v))}\n")
	Ok({})
}
