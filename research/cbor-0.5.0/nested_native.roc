app [main!] { cbor: "https://github.com/Karakatiza666/roc-cbor/releases/download/0.5.0/B5U2mPsWTtuxfCRMzqQxio2ecDv7CAzCoyEMENMh4FNF.tar.zst" }

# The minimal input of the wasm32 --opt=dev trap (memory access out of bounds) with roc-cbor 0.5.0, built for the
# native target: `roc build --opt=dev research/cbor-0.5.0/nested_native.roc`. The value comes from the arguments.
import cbor.Cbor

main! = |args| {
	n = args.len().to_u64()
	v : { r : { x : List(U64) } }
	v = { r: { x: [n] } }
	bytes = Cbor.encode(v)
	echo!("len=${bytes.len().to_str()} ${Str.inspect(bytes)}\n")
	Ok({})
}
