## Probe: a platform module that wraps `cbor.Cbor`, so an app needs no `cbor` entry in its header.
import cbor.Cbor

Codec :: [].{

	## The same type as `Cbor.Bytes` (an alias, not a new type).
	Bytes : Cbor.Bytes

	## The where-alias of `Cbor.Parseable`, spelled in the platform.
	a.Parseable(errs) :
		where [
			a.parser_for : Cbor -> (Cbor.State -> Try({ value : a, rest : Cbor.State }, errs)),
		]

	## The encoding value and the read position, for a custom `parser_for` in an app. The methods of `Cbor`
	## (`enc.parse_str(state)`) are found by static dispatch on these.
	Format : Cbor
	State : Cbor.State

	bytes : List(U8) -> Cbor.Bytes
	bytes = |list| Cbor.Bytes.(list)

	parse : List(U8) -> Try(a, [InvalidCbor(U64), ..errs]) where [a.Parseable([InvalidCbor(U64), ..errs])]
	parse = |raw| Cbor.parse(raw)

	encode : a -> List(U8) where [a.Cbor.Encodable([])]
	encode = |value| Cbor.encode(value)
}
