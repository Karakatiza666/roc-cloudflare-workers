## Bug: `wrap` needs `a` to be Cbor-parseable. `load` has no annotation and gives a value that Json
## parsed. `point` fixes `a` to Point, but the checker says the types differ and are not determined.
import Cbor

Point : { x : U64, y : U64 }

wrap : ({} -> Try(a, e)) -> ({} -> Try(a, e)) where [a.Cbor.Parseable([InvalidCbor(U64), ..errs])]
wrap = |f| f

load = |{}| Json.parse("{\"x\":1,\"y\":2}")

point : {} -> Try(Point, _)
point = wrap(load)

main! = |_args| {
	echo!(Str.inspect(point({})))
	Ok({})
}
