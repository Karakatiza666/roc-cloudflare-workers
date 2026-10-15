## The control: tiny.roc with an annotation on `load`. It compiles and prints Ok(7).
import Tiny

wrap : ({} -> Try(a, e)) -> ({} -> Try(a, e)) where [a.Tiny.Parseable([Empty])]
wrap = |f| f

load : {} -> Try(U64, [InvalidJson(Str)])
load = |{}| Json.parse("7")

number : {} -> Try(U64, _)
number = wrap(load)

main! = |_args| {
	echo!(Str.inspect(number({})))
	Ok({})
}
