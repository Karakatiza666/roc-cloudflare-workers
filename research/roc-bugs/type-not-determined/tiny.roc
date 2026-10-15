## Bug: `wrap` needs `a` to be Tiny-parseable. `load` has no annotation and gives a value that
## Json parsed. The annotation of `number` fixes `a` to U64, but the checker gives "type mismatch"
## (with the same type twice) and "type not determined".
import Tiny

wrap : ({} -> Try(a, e)) -> ({} -> Try(a, e)) where [a.Tiny.Parseable([Empty])]
wrap = |f| f

load = |{}| Json.parse("7")

number : {} -> Try(U64, _)
number = wrap(load)

main! = |_args| {
	echo!(Str.inspect(number({})))
	Ok({})
}
