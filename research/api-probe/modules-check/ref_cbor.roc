## Must not compile: a `Js.Ref` has no codec, so a ref cannot cross to JS in typed data (MC13, run.sh).
import Js
import Cbor

main! = |_args| {
	echo!(Str.inspect(Cbor.encode({ socket: Js.Ref.fake(7), n: 1.U64 })))
	Ok({})
}
