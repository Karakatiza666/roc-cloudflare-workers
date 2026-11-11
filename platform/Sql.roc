## SQL values and results (MODULES.md 5.1): the same types for D1 and, in phase B, for the storage of a Durable
## Object. `rows!` (no types) gives `Sql` values. A parameter is any value that encodes to a CBOR array: a list `[x]` or a
## tuple `(a, b)`. One value that is not a list, a tuple, a record or a tag is one parameter (`x` is `[x]`). Use `Sql.null`
## and `Sql.or_null` for NULL, `Sql.blob` for a blob. `Sql.blob(b)` is a `Sql.Blob`: it writes CBOR tag 64 (RFC 8746,
## uint8 array) round a byte string, so JS binds it as a blob also when it is the only parameter. A bare `List(U8)` is
## `BadParam`: roc-cbor 0.5.0 writes it as a plain byte string, so JS cannot tell one blob from a list of integer parameters.
## As an item of a list or a tuple, a `List(U8)` is a blob too.
## Typed data: the format, what a JS peer sees, and what survives a round trip are in MODULES.md 1, "Formats of typed data".
import Cbor
import cbor.Cbor as CborPkg

Sql := [Null, Int(I64), Real(F64), Text(Str), Blob(List(U8))].{
	is_eq : _

	## A `Sql` value as a parameter, for SQL that an app builds at run time (a list of `Sql` is one parameter list):
	## `Null` is CBOR null, `Int` an integer, `Real` an f64, `Text` text, `Blob` a byte string.
	encoder_for : encoding -> (Sql, state -> Try(state, err))
		where [
			encoding.encode_null : state -> Try(state, err),
			encoding.encode_i64 : I64, state -> Try(state, err),
			encoding.encode_f64 : F64, state -> Try(state, err),
			encoding.encode_str : Str, state -> Try(state, err),
			encoding.encode_bytes : List(U8), state -> Try(state, err),
		]
	encoder_for = |_| {
		Enc : encoding
		|v, state| match v {
			Null => Enc.encode_null(state)
			Int(i) => Enc.encode_i64(i, state)
			Real(f) => Enc.encode_f64(f, state)
			Text(t) => Enc.encode_str(t, state)
			Blob(b) => Enc.encode_bytes(b, state)
		}
	}

	## No parameters. A bare `[]` does not compile as a parameter list: its item type has no encoder to choose.
	none : List(Sql)
	none = []

	## One statement of `D1.batch!`. The parameters are encoded here, so a batch can hold statements of different types.
	stmt : Str, params -> Sql.Stmt where [params.Cbor.Writable]
	stmt = |sql, params| { sql, params: Cbor.encode(params) }

	## The parameters are the CBOR bytes of an array.
	Stmt : { sql : Str, params : List(U8) }

	## NULL as a parameter: CBOR null, bound as JS `null`.
	null : Sql.Null
	null = Sql.Null.Null

	## The type of `Sql.null`. It has its own encoder, so it encodes as CBOR null, not as a tag.
	Null := [Null].{
		encoder_for : encoding -> (Sql.Null, state -> Try(state, err))
			where [encoding.encode_null : state -> Try(state, err)]
		encoder_for = |_| {
			Enc : encoding
			|_, state| Enc.encode_null(state)
		}
	}

	## A parameter that can be NULL: `Ok(x)` encodes as `x`, `Err(_)` as NULL, for any error type. A bare `Err(Null)` of
	## an annotated `Try(a, [Null])` also encodes as CBOR null (NULL). A tag with a payload encodes as a map: `BadParam`.
	## The parameters are an array (a list or a tuple), so a NULL item stays. In a record that crosses as CBOR (an RPC
	## argument or reply, a queue message, a cell, a `Memo` value, an attachment) a field of `Sql.null`, of `Sql.or_null` or of
	## `Err(Null)` writes CBOR null (roc-cbor 0.5.0). A cell, an attachment and a `Memo` value read it back as `Err(Null)`.
	## RPC and queue reads (`Cbor.js_values`) read it as no key: there, use `x ?: a` or `x : Try(a, [Missing])`.
	or_null : Try(a, _) -> Sql.OrNull(a)
	or_null = |t| match t {
		Ok(x) => Sql.OrNull.Some(x)
		Err(_) => Sql.OrNull.None
	}

	## The type of `Sql.or_null`.
	OrNull(a) := [Some(a), None].{
		encoder_for : encoding -> (Sql.OrNull(a), state -> Try(state, err))
			where [encoding.encode_null : state -> Try(state, err), a.encoder_for : encoding -> (a, state -> Try(state, err))]
		encoder_for = |enc| {
			Enc : encoding
			A : a
			enc_a = A.encoder_for(enc)
			|v, state| match v {
				Some(x) => enc_a(x, state)
				None => Enc.encode_null(state)
			}
		}
	}

	## A blob as a parameter or a column value: CBOR tag 64 (RFC 8746, a uint8 array) round a byte string. JS reads the tag
	## as a `Uint8Array` that D1 binds as a blob, also as the only parameter (`db.run!(sql, Sql.blob(b))` is `[Sql.blob(b)]`).
	## A bare `List(U8)` is a byte string with no tag: it stays `BadParam`. Use `Sql.blob(b)` for a blob. `blob.to_list()` gives the list back.
	blob : List(U8) -> Sql.Blob
	blob = |list| Sql.Blob.Blob(list)

	## The type of `Sql.blob`. Its own type, not `List(U8)` and not `Cbor.Bytes`, so the compiler refuses a blob where a list of
	## integers goes. It reads the tag, a plain byte string, and (with `BytesFromArray`, in `Cbor.sql_rows`) the array of integers
	## 0 to 255 that D1 gives for a BLOB column: a record field `data : Sql.Blob` reads a BLOB of `all!` and `first!`.
	Blob := [Blob(List(U8))].{
		is_eq : _

		encoder_for : CborPkg -> (Sql.Blob, CborPkg.Writer -> Try(CborPkg.Writer, err))
		encoder_for = |_| |Sql.Blob.Blob(list), w| CborPkg.encode_tagged(64, Cbor.bytes(list), w)

		parser_for : CborPkg -> (CborPkg.Reader -> Try({ value : Sql.Blob, rest : CborPkg.Reader }, [InvalidCbor(U64)]))
		parser_for = |enc| |state| {
			start = match CborPkg.peek(enc, state)? {
				Tag(64) => CborPkg.parse_cbor_tag(enc, state)?.rest
				_ => state
			}
			bytes : { value : CborPkg.Bytes, rest : CborPkg.Reader }
			bytes = CborPkg.parse_item(enc, start)?
			Ok({ value: Sql.Blob.Blob(bytes.value.to_list()), rest: bytes.rest })
		}

		## The bytes as a list.
		to_list : Sql.Blob -> List(U8)
		to_list = |Sql.Blob.Blob(list)| list
	}

	## The `meta` of a query. `last_row_id` is `Err(Rounded)` when D1 gave it with a size of 2^53 or more: D1 gives each
	## number as a JS `Number`, so a larger rowid is rounded (MODULES.md 5.1, "Integers in rows").
	Info : { changes : U64, last_row_id : Try(I64, [Rounded]), rows_read : U64, rows_written : U64, duration_ms : F64 }

	## Rows with no types: the column names, then one list of values for each row.
	Rows : { columns : List(Str), rows : List(List(Sql)) }

	## A constraint failure (MC9): the kind from the extended code in the message text, and the SQLite text
	## (5.1, table "Constraint kinds"). A flat domain tag `Constraint(Sql.Constraint)`, not in `Infra`.
	Constraint : { kind : [PrimaryKey, Unique, ForeignKey, Check, NotNull, Trigger, Datatype, Other], message : Str }
}

# Sql.blob (tag 64 round a byte string, RFC 8746). A bare List(U8) is a byte string with no tag, so JS can tell the two apart.
expect Cbor.encode(Sql.blob([1, 2, 3])) == [0xd8, 0x40, 0x43, 0x01, 0x02, 0x03]
expect Cbor.encode(Sql.blob([])) == [0xd8, 0x40, 0x40]
expect Cbor.encode([1.U8, 2, 3]) == [0x43, 0x01, 0x02, 0x03]
expect Cbor.encode(Cbor.bytes([1, 2, 3])) == [0x43, 0x01, 0x02, 0x03]
# As an item of a tuple and of a list, and in a record.
expect Cbor.encode(("k", Sql.blob([1]))) == [0x82, 0x61, 0x6b, 0xd8, 0x40, 0x41, 0x01]
expect Cbor.encode([Sql.blob([1]), Sql.blob([])]) == [0x82, 0xd8, 0x40, 0x41, 0x01, 0xd8, 0x40, 0x40]
expect Cbor.encode({ d: Sql.blob([9]) }) == [0xa1, 0x61, 0x64, 0xd8, 0x40, 0x41, 0x09]
# All 256 byte values, in one blob: the head of the byte string has a length of 2 bytes (0x59 0x01 0x00).
all_bytes : List(U8)
all_bytes = {
	var $list = []
	for i in (0.U64).until(256) {
		$list = $list.append(i.to_u8_wrap())
	}
	$list
}
expect all_bytes.len() == 256
expect Cbor.encode(Sql.blob(all_bytes)).take_first(5) == [0xd8, 0x40, 0x59, 0x01, 0x00]
expect {
	got : Try(Sql.Blob, _)
	got = Cbor.parse(Cbor.encode(Sql.blob(all_bytes)))
	got == Ok(Sql.blob(all_bytes)) and got.map_ok(|b| b.to_list()) == Ok(all_bytes)
}
expect {
	got : Try(Sql.Blob, _)
	got = Cbor.parse(Cbor.encode(Sql.blob([])))
	got == Ok(Sql.blob([]))
}
# Reads: the tag, a plain byte string, and (with sql_rows) the array of integers that D1 gives for a BLOB column.
expect {
	tagged : Try(Sql.Blob, _)
	tagged = Cbor.parse([0xd8, 0x40, 0x42, 0x07, 0x08])
	plain : Try(Sql.Blob, _)
	plain = Cbor.parse([0x42, 0x07, 0x08])
	tagged == Ok(Sql.blob([7, 8])) and plain == Ok(Sql.blob([7, 8]))
}
expect {
	strict : Try(Sql.Blob, _)
	strict = Cbor.parse([0x82, 0x07, 0x08])
	row : Try(Sql.Blob, _)
	row = Cbor.parse_with([0x82, 0x07, 0x08], { allow: Cbor.sql_rows })
	strict.is_err() and row == Ok(Sql.blob([7, 8]))
}
expect {
	row : Try({ id : I64, data : Sql.Blob }, _)
	row = Cbor.parse_with(Cbor.encode({ id: 1.I64, data: Cbor.u8_array([0, 255]) }), { allow: Cbor.sql_rows })
	row == Ok({ id: 1, data: Sql.blob([0, 255]) })
}
# Another tag, a text and a tag round another item are not a blob.
expect {
	other_tag : Try(Sql.Blob, _)
	other_tag = Cbor.parse([0xd8, 0x41, 0x41, 0x01])
	text : Try(Sql.Blob, _)
	text = Cbor.parse([0x61, 0x61])
	other_tag.is_err() and text.is_err()
}
# A Sql.Blob is not a List(U8), and a blob is not equal to another blob with other bytes.
expect Sql.blob([1]) != Sql.blob([2])
