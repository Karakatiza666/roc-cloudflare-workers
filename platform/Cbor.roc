## Typed data as CBOR (MODULES.md MC5, API.md 5.2). The module wraps `Cbor` of the package `roc-cbor` 0.1.0, so an app
## needs no `cbor` entry in its header: `import pf.Cbor`. Each type here is an alias of the type of the package, not a new
## type. An app that also adds the same package URL gets the same types, and values pass between the two.
##
## | Name | Kind | The package |
## | --- | --- | --- |
## | `Bytes` | type | `Cbor.Bytes`: a CBOR byte string. `bytes(list)` makes one (`Bytes` is an alias, so `Bytes.(list)` does not compile in an app), `b.to_list()` reads it. |
## | `Options` | type | `Cbor.Options`: the options of `parse_with`. |
## | `Step` | type | `Cbor.Step`: one step of a path (`Index` or `Key`). |
## | `Parseable(errs)` | `where` alias | `Cbor.Parseable(errs)`: a type that `parse` can read. |
## | `Encodable(err)` | `where` alias | `Cbor.Encodable(err)`: a type that `encode` can write. |
## | `Format` | type | `Cbor`: the encoding value of a custom `parser_for` or `encoder_for`. |
## | `State` | type | `Cbor.State`: the read position of a custom `parser_for`. |
## | `parse`, `parse_camel`, `parse_with` | function | Read one item of the type of the annotation. |
## | `path_at` | function | The path to the item at a byte position. |
## | `encode` | function | Write one value. |
## | `bytes` | function | The constructor of `Bytes`. |
##
## ```roc
## import pf.Cbor
##
## Row : { id : I64, avatar : Cbor.Bytes }
##
## raw = Cbor.encode({ id: 7.I64, avatar: Cbor.bytes([1, 2, 3]) })
## row : Try(Row, _)
## row = Cbor.parse(raw)
## ```
## Typed data: the format, what a JS peer sees, and what survives a round trip are in MODULES.md 1, "Formats of typed data".
import cbor.Cbor as CborPkg

Cbor :: [].{

	## Bytes that cross as a CBOR byte string (major type 2). A `List(U8)` writes as an array of numbers.
	## `Cbor.bytes(list)` makes one (an alias has no constructor: `Cbor.Bytes.(list)` gives "expected nominal type"), and `bytes.to_list()` gives the list back.
	## The same type as `Bytes` of the package.
	Bytes : CborPkg.Bytes

	## The options of `parse_with`: `{ fields : [Snake, Camel], int_from_text : Bool }`.
	## The same type as `Options` of the package.
	Options : CborPkg.Options

	## One step of the path that `path_at` gives: `Index(U64)` or `Key(Str)`.
	## The same type as `Step` of the package.
	Step : CborPkg.Step

	## A type that `parse` can read. Use it in the `where` clause of a function that calls `parse` (or a D1 read) with a
	## type variable: `where [a.Cbor.Parseable([InvalidCbor(U64), ..errs])]`.
	## The same constraint as `Parseable` of the package.
	a.Parseable(errs) :
		where [
			a.parser_for : CborPkg -> (CborPkg.State -> Try({ value : a, rest : CborPkg.State }, errs)),
		]

	## A type that `encode` can write. Use it in the `where` clause of a function that calls `encode` with a type
	## variable: `where [a.Cbor.Encodable([])]`.
	## The same constraint as `Encodable` of the package.
	a.Encodable(err) :
		where [
			a.encoder_for : CborPkg -> (a, List(U8) -> Try(List(U8), err)),
		]

	## The encoding value. A custom `parser_for` or `encoder_for` in an app takes it as its argument:
	## `parser_for : Cbor.Format -> (Cbor.State -> Try({ value : T, rest : Cbor.State }, [InvalidCbor(U64)]))`.
	## The methods of the codec protocol (`enc.parse_str(state)`) are found by static dispatch on it.
	## The same type as `Cbor` of the package.
	Format : CborPkg

	## The read position of a parse. A custom `parser_for` passes it from step to step. Its fields are hidden.
	## The same type as `State` of the package.
	State : CborPkg.State

	## Makes `Bytes` from a list: the same as `CborPkg.Bytes.(list)` of the package.
	bytes : List(U8) -> CborPkg.Bytes
	bytes = |list| CborPkg.Bytes.(list)

	## Reads one CBOR item of the type `a` from all of `raw`. The type comes from the annotation.
	## The error is `InvalidCbor(pos)`, with the byte position of the problem, or `MissingRequiredField(name)` from the
	## derived parser of a record. Bytes after the item are an error at the position of the first extra byte.
	parse : List(U8) -> Try(a, [InvalidCbor(U64), ..errs]) where [a.Parseable([InvalidCbor(U64), ..errs])]
	parse = |raw| CborPkg.parse(raw)

	## Like `parse`, with record fields in camelCase: `user_id` is read from `userId`.
	parse_camel : List(U8) -> Try(a, [InvalidCbor(U64), ..errs]) where [a.Parseable([InvalidCbor(U64), ..errs])]
	parse_camel = |raw| CborPkg.parse_camel(raw)

	## Like `parse`, with options: `{ fields: Snake, int_from_text: Bool.False }`.
	## `int_from_text: Bool.True` reads an integer type also from text that is a canonical decimal integer in its range.
	parse_with : List(U8), CborPkg.Options -> Try(a, [InvalidCbor(U64), ..errs]) where [a.Parseable([InvalidCbor(U64), ..errs])]
	parse_with = |raw, options| CborPkg.parse_with(raw, options)

	## The path from the root to the item that starts at byte `pos`: the array indexes and the map keys.
	## Use it with the position of `InvalidCbor(pos)` to find the field of the error.
	## The path of the root is `[]`. `Err(NotFound)` when no item starts at `pos`.
	path_at : List(U8), U64 -> Try(List(CborPkg.Step), [NotFound])
	path_at = |raw, pos| CborPkg.path_at(raw, pos)

	## Writes `value` as one CBOR item. It cannot fail. A `Secret` in `value` does not compile.
	encode : a -> List(U8) where [a.Encodable([])]
	encode = |value| CborPkg.encode(value)
}
