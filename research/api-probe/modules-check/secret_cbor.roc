## Must not compile: a `Secret` has no codec, so it cannot cross to JS in typed data (run.sh).
import Secret
import Cbor

main! = |_args| {
	echo!(Str.inspect(Cbor.encode({ token: Secret.from_str("hunter2"), n: 1.U64 })))
	Ok({})
}
