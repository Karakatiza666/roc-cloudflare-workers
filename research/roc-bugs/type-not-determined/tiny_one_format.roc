## The control: tiny.roc with no Json. It compiles and prints Ok(7).
import Tiny

wrap : ({} -> Try(a, e)) -> ({} -> Try(a, e)) where [a.Tiny.Parseable([Empty])]
wrap = |f| f

load = |{}| Tiny.parse_u64(Tiny.Tiny, [7]).map_ok(|p| p.value)

number : {} -> Try(U64, _)
number = wrap(load)

main! = |_args| {
	echo!(Str.inspect(number({})))
	Ok({})
}
