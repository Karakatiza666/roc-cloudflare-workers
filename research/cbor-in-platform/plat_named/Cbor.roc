## Probe: a platform module that wraps `cbor.Cbor`, so an app needs no `cbor` entry in its header.
import cbor.Cbor as CborPkg

Cbor :: [].{

	## The same type as `CborPkg.Bytes` (an alias, not a new type).
	Bytes : CborPkg.Bytes

	## The where-alias of `Cbor.Parseable`, spelled in the platform.
	a.Parseable(errs) :
		where [
			a.parser_for : CborPkg -> (CborPkg.State -> Try({ value : a, rest : CborPkg.State }, errs)),
		]

	## The encoding value and the read position, for a custom `parser_for` in an app. The methods of `Cbor`
	## (`enc.parse_str(state)`) are found by static dispatch on these.
	Format : CborPkg
	State : CborPkg.State

	bytes : List(U8) -> CborPkg.Bytes
	bytes = |list| CborPkg.Bytes.(list)

	parse : List(U8) -> Try(a, [InvalidCbor(U64), ..errs]) where [a.Parseable([InvalidCbor(U64), ..errs])]
	parse = |raw| CborPkg.parse(raw)

	encode : a -> List(U8) where [a.CborPkg.Encodable([])]
	encode = |value| CborPkg.encode(value)
}
