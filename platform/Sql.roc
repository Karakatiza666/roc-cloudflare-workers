## SQL values and results (MODULES.md 5.1): the same types for D1 and, in phase B, for the storage of a Durable
## Object. `rows!` (no types) gives `Sql` values. A parameter is any value that encodes to a CBOR array: a list `[x]` or a
## tuple `(a, b)`. One value that is not a list, a tuple, a record or a tag is one parameter (`x` is `[x]`). Use `Sql.null`
## and `Sql.or_null` for NULL, `Sql.blob` for a blob (a `List(U8)` is a list of parameters).
## Typed data: the format, what a JS peer sees, and what survives a round trip are in MODULES.md 1, "Formats of typed data".
import Cbor

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

	## A blob as a parameter: a CBOR byte string, bound as a `Uint8Array`.
	blob : List(U8) -> Cbor.Bytes
	blob = |list| Cbor.bytes(list)

	## The `meta` of a query. `last_row_id` is `Err(Rounded)` when D1 gave it with a size of 2^53 or more: D1 gives each
	## number as a JS `Number`, so a larger rowid is rounded (MODULES.md 5.1, "Integers in rows").
	Info : { changes : U64, last_row_id : Try(I64, [Rounded]), rows_read : U64, rows_written : U64, duration_ms : F64 }

	## Rows with no types: the column names, then one list of values for each row.
	Rows : { columns : List(Str), rows : List(List(Sql)) }

	## A constraint failure (MC9): the kind from the extended code in the message text, and the SQLite text
	## (5.1, table "Constraint kinds"). A flat domain tag `Constraint(Sql.Constraint)`, not in `Infra`.
	Constraint : { kind : [PrimaryKey, Unique, ForeignKey, Check, NotNull, Trigger, Datatype, Other], message : Str }
}
