## Typed data as CBOR (MODULES.md MC5, API.md 5.2). The module wraps `Cbor` of the package `roc-cbor` 0.5.0, so an app
## needs no `cbor` entry in its header: `import pf.Cbor`. Each type here is an alias of the type of the package, not a new
## type. An app that also adds the same package URL gets the same types, and values pass between the two.
##
## | Name | Kind | The package |
## | --- | --- | --- |
## | `Bytes` | type | `Cbor.Bytes`: it writes as a CBOR byte string and reads a byte string or an array of integers 0 to 255 (a D1 BLOB). `bytes(list)` makes one (`Bytes` is an alias, so `Bytes.(list)` does not compile in an app), `b.to_list()` reads it. |
## | `Options` | type | `Cbor.Options`: the options of `parse_with`. |
## | `Leniency` | type | `Cbor.Leniency`: one lenient read, for the option `allow` of `parse_with`. |
## | `sql_rows` | value | `Cbor.sql_rows`: the leniencies for rows of a SQL database. |
## | `js_values` | value | `[UndefinedAsNull, NullAsAbsent]`: the leniencies of the platform for a value that comes from JS (an RPC argument or reply, a queue message, a Workers AI result). |
## | `legacy_0_2` | value | `[PaddedNumbers, BytesFromArray]`: the leniencies that read the bytes of roc-cbor 0.2.3 (platform 0.0.9), for a migration once. |
## | `U8Array` | type | `Cbor.U8Array`: bytes as an array of integers 0 to 255, for a JS peer that needs a plain array (Workers AI `image`, `audio`). `u8_array(list)` makes one. |
## | `Step` | type | `Cbor.Step`: one step of a path (`Index` or `Key`). |
## | `Parseable(errs)` | `where` alias | `Cbor.Parseable(errs)`: a type that `parse` can read. |
## | `Encodable(err)` | `where` alias | `Cbor.Encodable(err)`: a type that `encode` can write. |
## | `Readable(errs)` | `where` alias | `Cbor.Readable(errs)`: `Parseable` with `InvalidCbor(U64)` and `MissingRequiredField(Str)` in the error row. |
## | `Writable` | `where` alias | `Cbor.Writable`: the same as `Encodable([])`. |
## | `Format` | type | `Cbor`: the encoding value of a custom `parser_for` or `encoder_for`. |
## | `Reader` | type | `Cbor.Reader`: the read position of a custom `parser_for`. `State` is the same type (the name of 0.2). |
## | `Writer` | type | `Cbor.Writer`: the output of a custom `encoder_for`. |
## | `parse`, `parse_camel`, `parse_with` | function | Read one item of the type of the annotation. |
## | `parse_legacy` | function | `parse_with(raw, { allow: legacy_0_2 })`: read bytes of roc-cbor 0.2.3, for a migration once (MODULES.md 1, "Migration from platform 0.0.9"). |
## | `path_at` | function | The path to the item at a byte position. |
## | `encode` | function | Write one value. |
## | `bytes` | function | The constructor of `Bytes`. |
## | `u8_array` | function | The constructor of `U8Array`. |
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

	## Bytes that cross as a CBOR byte string (major type 2). A `List(U8)` also writes a byte string (roc-cbor 0.5.0).
	## It reads a byte string. An array of integers 0 to 255 (a D1 BLOB, which JS gives as an array) needs `BytesFromArray`
	## (in `sql_rows`): the D1 reads of the platform have it.
	## `Cbor.bytes(list)` makes one (an alias has no constructor: `Cbor.Bytes.(list)` gives "expected nominal type"), and `bytes.to_list()` gives the list back.
	## The same type as `Bytes` of the package.
	Bytes : CborPkg.Bytes

	## The options of `parse_with`: `{ fields ?: [Snake, Camel], allow ?: List(Leniency), duplicate_keys ?: .., .. }`.
	## Each field is optional: `{}` is the same as `parse`. The same type as `Options` of the package.
	Options : CborPkg.Options

	## One lenient read, for the option `allow`: `BoolFromInt`, `FloatToInt`, `IntFromText`, `DecFromText`, `NullAsAbsent`,
	## `UndefinedAsNull`, `PaddedNumbers`, `BytesFromArray`, `BytesFromBase64`, `IndefiniteLength`. The same type as `Leniency` of the package.
	Leniency : CborPkg.Leniency

	## The leniencies of a SQL row: `[BoolFromInt, FloatToInt, NullAsAbsent, UndefinedAsNull, BytesFromArray]`.
	sql_rows : List(CborPkg.Leniency)
	sql_rows = CborPkg.sql_rows

	## The leniencies of the platform for a value that comes from JS: an RPC argument and an RPC reply (`Rpc`), a
	## message of `Queue.json` and `Queue.v8`, the result of `Ai.run!`. A JS object gives `undefined` or `null` for a
	## field that it does not set: `undefined` reads as `null`, and a `null` value in a record is no key. So an optional
	## field (`x ?: a`) and a `Try(a, [Missing])` field read it as absent. A `Try(a, [Null])` record field there reads a
	## `null` as no key too (`MissingRequiredField`): use `x ?: a` or `Try(a, [Missing])` for it.
	## Data that Roc wrote and stores (`Object.cell`, `Object.attachment`, `Memo`) is read strict.
	js_values : List(CborPkg.Leniency)
	js_values = [UndefinedAsNull, NullAsAbsent]

	## The leniencies that read the bytes of roc-cbor 0.2.3 (the version of platform 0.0.9): `PaddedNumbers` (an array or a
	## map of 24 to 65,535 items has a head of 3 bytes) and `BytesFromArray` (a `List(U8)` is an array of integers).
	## For a migration once: read the old value with them, write it again (MODULES.md 1, "Migration from platform 0.0.9").
	## A `Try(a, [Null])` record field of 0.2.3 with `Err(Null)` has no key: change the field to `x ?: a` or
	## `Try(a, [Missing])` (the roc-cbor 0.2.2 rule), no leniency reads it as `Err(Null)`.
	legacy_0_2 : List(CborPkg.Leniency)
	legacy_0_2 = [PaddedNumbers, BytesFromArray]

	## One step of the path that `path_at` gives: `Index(U64)` or `Key(Str)`.
	## The same type as `Step` of the package.
	Step : CborPkg.Step

	## A type that `parse` can read. Use it in the `where` clause of a function that calls `parse` (or a D1 read) with a
	## type variable: `where [a.Cbor.Parseable([InvalidCbor(U64), ..errs])]`.
	## The same constraint as `Parseable` of the package.
	a.Parseable(errs) :
		where [
			a.parser_for : CborPkg -> (CborPkg.Reader -> Try({ value : a, rest : CborPkg.Reader }, errs)),
		]

	## A type that `encode` can write. Use it in the `where` clause of a function that calls `encode` with a type
	## variable: `where [a.Cbor.Encodable([])]`.
	## The same constraint as `Encodable` of the package.
	a.Encodable(err) :
		where [
			a.encoder_for : CborPkg -> (a, CborPkg.Writer -> Try(CborPkg.Writer, err)),
		]

	## The short form of `Parseable`: `where [a.Cbor.Readable(errs)]` is `where [a.Cbor.Parseable([InvalidCbor(U64), MissingRequiredField(Str), ..errs])]`.
	## A function with it can `match` on `InvalidCbor(pos)` and `MissingRequiredField(field)`.
	## The same constraint as `Readable` of the package.
	a.Readable(errs) :
		where [
			a.parser_for : CborPkg -> (CborPkg.Reader -> Try({ value : a, rest : CborPkg.Reader }, [InvalidCbor(U64), MissingRequiredField(Str), ..errs])),
		]

	## The short form of `Encodable([])`: `where [a.Cbor.Writable]`.
	## The same constraint as `Writable` of the package.
	a.Writable :
		where [
			a.encoder_for : CborPkg -> (a, CborPkg.Writer -> Try(CborPkg.Writer, [])),
		]

	## The encoding value. A custom `parser_for` or `encoder_for` in an app takes it as its argument:
	## `parser_for : Cbor.Format -> (Cbor.Reader -> Try({ value : T, rest : Cbor.Reader }, [InvalidCbor(U64)]))`,
	## `encoder_for : Cbor.Format -> (T, Cbor.Writer -> Try(Cbor.Writer, err))`.
	## The methods of the codec protocol (`enc.parse_str(state)`) are found by static dispatch on it.
	## The same type as `Cbor` of the package.
	Format : CborPkg

	## The read position of a parse. A custom `parser_for` passes it from step to step. Its fields are hidden.
	## The same type as `Reader` of the package.
	Reader : CborPkg.Reader

	## The name of `Reader` in roc-cbor 0.2: the same type.
	State : CborPkg.Reader

	## The output of an encode. A custom `encoder_for` gets it and writes each item with an `encode_*` function.
	## The same type as `Writer` of the package.
	Writer : CborPkg.Writer

	## Makes `Bytes` from a list: the same as `CborPkg.Bytes.(list)` of the package.
	bytes : List(U8) -> CborPkg.Bytes
	bytes = |list| CborPkg.Bytes.(list)

	## Bytes that cross as a CBOR array of integers 0 to 255: a JS peer gets a plain `Array` of numbers. For an API
	## that takes a JSON array of bytes (Workers AI: `image`, `audio`), where a `List(U8)` (a byte string, a JS
	## `Uint8Array`) does not fit. It reads an array only. `Cbor.u8_array(list)` makes one, `a.to_list()` reads it.
	## The same type as `U8Array` of the package.
	U8Array : CborPkg.U8Array

	## Makes `U8Array` from a list: the same as `CborPkg.U8Array.(list)` of the package.
	u8_array : List(U8) -> CborPkg.U8Array
	u8_array = |list| CborPkg.U8Array.(list)

	## Reads one CBOR item of the type `a` from all of `raw`. The type comes from the annotation.
	## The error is `InvalidCbor(pos)`, with the byte position of the problem, or `MissingRequiredField(name)` from the
	## derived parser of a record. Bytes after the item are an error at the position of the first extra byte.
	parse : List(U8) -> Try(a, [InvalidCbor(U64), ..errs]) where [a.Parseable([InvalidCbor(U64), ..errs])]
	parse = |raw| CborPkg.parse(raw)

	## Like `parse`, with record fields in camelCase: `user_id` is read from `userId`.
	parse_camel : List(U8) -> Try(a, [InvalidCbor(U64), ..errs]) where [a.Parseable([InvalidCbor(U64), ..errs])]
	parse_camel = |raw| CborPkg.parse_with(raw, { fields: Camel })

	## Like `parse`, with options: `{ fields: Camel, allow: [IntFromText] }`. Each field is optional, `{}` is the same as `parse`.
	## `allow: [IntFromText]` reads an integer type also from text that is a canonical decimal integer in its range.
	parse_with : List(U8), CborPkg.Options -> Try(a, [InvalidCbor(U64), ..errs]) where [a.Parseable([InvalidCbor(U64), ..errs])]
	parse_with = |raw, options| CborPkg.parse_with(raw, options)

	## Reads bytes that roc-cbor 0.2.3 wrote (platform 0.0.9): `parse_with(raw, { allow: legacy_0_2 })`. For a migration
	## once: read each old value with it and write it again with `encode` (`Object.Cell.migrate!` does both for a cell).
	## Do not keep it as the read of each request: new data reads strict.
	parse_legacy : List(U8) -> Try(a, [InvalidCbor(U64), ..errs]) where [a.Parseable([InvalidCbor(U64), ..errs])]
	parse_legacy = |raw| CborPkg.parse_with(raw, { allow: [PaddedNumbers, BytesFromArray] })

	## The path from the root to the item that starts at byte `pos`: the array indexes and the map keys.
	## Use it with the position of `InvalidCbor(pos)` to find the field of the error.
	## The path of the root is `[]`. `Err(NotFound)` when no item starts at `pos`.
	path_at : List(U8), U64 -> Try(List(CborPkg.Step), [NotFound])
	path_at = |raw, pos| CborPkg.path_at(raw, pos)

	## Writes `value` as one CBOR item. It cannot fail. A `Secret` in `value` does not compile.
	encode : a -> List(U8) where [a.Encodable([])]
	encode = |value| CborPkg.encode(value)
}

# A BLOB (a JS array of 0..255) reads into Bytes with `BytesFromArray` (roc-cbor 0.5.0), and not with the strict reader.
expect {
	got : Try({ b : Cbor.Bytes }, _)
	got = Cbor.parse_with(Cbor.encode({ b: CborPkg.U8Array.([1, 2, 255]) }), { allow: [BytesFromArray] })
	got == Ok({ b: Cbor.bytes([1, 2, 255]) })
}
expect {
	got : Try({ b : Cbor.Bytes }, _)
	got = Cbor.parse(Cbor.encode({ b: CborPkg.U8Array.([1, 2, 255]) }))
	got.is_err()
}
# A List(U8) writes a byte string (roc-cbor 0.5.0). A Dec literal list is CBOR integers.
expect Cbor.encode([1.U8, 2]) == [0x42, 0x01, 0x02]
expect Cbor.encode([1]) == [0x81, 0x01]
expect Cbor.encode([3.14159]) == [0x81, 0xc4, 0x82, 0x24, 0x1a, 0x00, 0x04, 0xcb, 0x2f]

# legacy_0_2: the bytes that roc-cbor 0.2.3 wrote (research/cbor-0.5.0/legacy/write_0_2_3.roc pins them).
# A List(U8) of 24 items is an array with a head of 3 bytes (0x99 0x00 0x18): parse_legacy reads it, parse does not.
legacy_bytes : List(U8)
legacy_bytes = [0xa2, 0x64, 0x64, 0x61, 0x74, 0x61, 0x99, 0x00, 0x18].concat(List.repeat(7, 24)).concat([0x61, 0x6e, 0x01])

expect {
	got : Try({ data : List(U8), n : I64 }, _)
	got = Cbor.parse_legacy(legacy_bytes)
	got == Ok({ data: List.repeat(7, 24), n: 1 })
}
expect {
	got : Try({ data : List(U8), n : I64 }, _)
	got = Cbor.parse(legacy_bytes)
	got == Err(InvalidCbor(6))
}
# Each leniency alone is not enough: the head of 3 bytes needs PaddedNumbers, the array needs BytesFromArray.
expect {
	pad : Try({ data : List(U8), n : I64 }, _)
	pad = Cbor.parse_with(legacy_bytes, { allow: [PaddedNumbers] })
	arr : Try({ data : List(U8), n : I64 }, _)
	arr = Cbor.parse_with(legacy_bytes, { allow: [BytesFromArray] })
	pad.is_err() and arr.is_err()
}
# A record of 0.2.3 with a short List(U8), a Bool, an Err(Null) field (no key), a Dec and a list of records.
expect {
	old = [165, 100, 100, 97, 116, 97, 130, 1, 2, 101, 105, 116, 101, 109, 115, 129, 161, 97, 110, 25, 1, 44, 100, 110, 97, 109, 101, 97, 97, 98, 111, 110, 245, 101, 112, 114, 105, 99, 101, 196, 130, 32, 15]
	got : Try({ name : Str, data : List(U8), on : Bool, note : Try(Str, [Missing]), price : Dec, items : List({ n : I64 }) }, _)
	got = Cbor.parse_legacy(old)
	got == Ok({ name: "a", data: [1, 2], on: Bool.True, note: Err(Missing), price: 1.5, items: [{ n: 300 }] })
}
# The value written again (the migration) reads strict.
expect {
	got : Try({ data : List(U8), n : I64 }, _)
	got = Cbor.parse_legacy(legacy_bytes)
	again : Try({ data : List(U8), n : I64 }, _)
	again = match got {
		Ok(v) => Cbor.parse(Cbor.encode(v))
		Err(e) => Err(e)
	}
	again == Ok({ data: List.repeat(7, 24), n: 1 })
}
# js_values: undefined (f7) and null (f6) of a JS object are no key for an optional field. The strict reader refuses both.
expect {
	# {"a": 1, "b": undefined, "c": null}
	raw = [0xa3, 0x61, 0x61, 0x01, 0x61, 0x62, 0xf7, 0x61, 0x63, 0xf6]
	lenient : Try({ a : I64, b : Try(Str, [Missing]), c : Try(Str, [Missing]) }, _)
	lenient = Cbor.parse_with(raw, { allow: Cbor.js_values })
	strict : Try({ a : I64, b : Try(Str, [Missing]), c : Try(Str, [Missing]) }, _)
	strict = Cbor.parse(raw)
	lenient == Ok({ a: 1, b: Err(Missing), c: Err(Missing) }) and strict == Err(InvalidCbor(6))
}
# U8Array writes an array of integers (a JS Array), Bytes a byte string (a Uint8Array).
expect Cbor.encode({ a: Cbor.u8_array([1, 2]) }) == [0xa1, 0x61, 0x61, 0x82, 0x01, 0x02]
expect Cbor.encode({ a: Cbor.bytes([1, 2]) }) == [0xa1, 0x61, 0x61, 0x42, 0x01, 0x02]
# A U128 and an I128 outside 64 bits write a bignum (tag 2, tag 3): js/cbor.js reads it as a BigInt.
expect Cbor.encode(18_446_744_073_709_551_616.U128) == [0xc2, 0x49, 0x01, 0, 0, 0, 0, 0, 0, 0, 0]
expect Cbor.encode(-18_446_744_073_709_551_617.I128) == [0xc3, 0x49, 0x01, 0, 0, 0, 0, 0, 0, 0, 0]
expect Cbor.encode(5.U128) == [0x05]
