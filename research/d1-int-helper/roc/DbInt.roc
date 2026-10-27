## Prototype (option C): a number-like type for a D1 INTEGER column. Not in the platform.
## It is an I64 with the operators of a number, number literals (`from_numeral`), and a strict read:
## it reads only canonical decimal text (from `CAST(x AS TEXT)`). A CBOR number is an error, also a small one,
## so a SELECT with no CAST fails at the first test, not at the first id of 2^53 or more.
DbInt :: { v : I64 }.{

	from_numeral : Numeral -> Try(DbInt, [InvalidNumeral(Str)])
	from_numeral = |n| match I64.from_numeral(n) {
		Ok(v) => Ok(DbInt.{ v })
		Err(e) => Err(e)
	}

	from_i64 : I64 -> DbInt
	from_i64 = |v| DbInt.{ v }

	to_i64 : DbInt -> I64
	to_i64 = |x| x.v

	to_str : DbInt -> Str
	to_str = |x| x.v.to_str()

	from_str : Str -> Try(DbInt, [BadInt])
	from_str = |s| match I64.from_str(s) {
		Ok(v) if v.to_str() == s => Ok(DbInt.{ v })
		_ => Err(BadInt)
	}

	plus : DbInt, DbInt -> DbInt
	plus = |a, b| DbInt.{ v: a.v + b.v }

	minus : DbInt, DbInt -> DbInt
	minus = |a, b| DbInt.{ v: a.v - b.v }

	times : DbInt, DbInt -> DbInt
	times = |a, b| DbInt.{ v: a.v * b.v }

	div_trunc_by : DbInt, DbInt -> DbInt
	div_trunc_by = |a, b| DbInt.{ v: a.v // b.v }

	rem_by : DbInt, DbInt -> DbInt
	rem_by = |a, b| DbInt.{ v: a.v % b.v }

	negate : DbInt -> DbInt
	negate = |a| DbInt.{ v: -a.v }

	is_lt : DbInt, DbInt -> Bool
	is_lt = |a, b| a.v < b.v

	is_lte : DbInt, DbInt -> Bool
	is_lte = |a, b| a.v <= b.v

	is_gt : DbInt, DbInt -> Bool
	is_gt = |a, b| a.v > b.v

	is_gte : DbInt, DbInt -> Bool
	is_gte = |a, b| a.v >= b.v

	is_eq : _

	to_hash : _

	to_inspect : DbInt -> Str
	to_inspect = |x| x.v.to_str()

	## Strict read: decimal text only.
	parser_for : encoding -> (state -> Try({ value : DbInt, rest : state }, err))
		where [
			encoding.parse_str : encoding, state -> Try({ value : Str, rest : state }, err),
			# Called only to get the error of the format at this position.
			encoding.parse_bytes : encoding, state -> Try({ value : List(U8), rest : state }, err),
		]
	parser_for = |encoding| {
		Encoding : encoding

		|state| {
			text = Encoding.parse_str(encoding, state)?
			match DbInt.from_str(text.value) {
				Ok(x) => Ok({ value: x, rest: text.rest })
				Err(BadInt) => {
					# Not reachable with a byte string here; parse_bytes of a text item gives the error at `state`.
					b = Encoding.parse_bytes(encoding, state)?
					Ok({ value: DbInt.{ v: b.value.len().to_i64_wrap() }, rest: b.rest })
				}
			}
		}
	}

	## Write: a CBOR integer. The platform JS binds an integer of size 2^53 or more as decimal text.
	encoder_for : encoding -> (DbInt, state -> Try(state, err))
		where [encoding.encode_i64 : I64, state -> Try(state, err)]
	encoder_for = |_| {
		Encoding : encoding

		|x, state| Encoding.encode_i64(x.v, state)
	}
}
