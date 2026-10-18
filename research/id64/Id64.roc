## A 64-bit id for a D1 INTEGER column (MODULES.md 5.1). The value is an I64 with the bits of a U64 or of 8 bytes.
## The type has no number methods: `id + 1` and `id < other` do not compile. The only way to a number is `to_u64` or `to_i64`.
##
## | Part | Rule |
## | --- | --- |
## | Equality, hash | By the I64 value. |
## | Order | None (no `is_lt`): the signed order of SQL differs from the U64 order. |
## | CBOR write | The decimal text of the I64 (R-IK2): a SQL parameter binds as text. |
## | CBOR read | Decimal text (from `CAST(id AS TEXT)`) or a CBOR integer. |
## | JSON | The same text, so a browser does not round it. |
##
## The backing is a record, not a bare I64: an opaque type over a bare number would get the codecs of the number.
Id64 :: { bits : I64 }.{

	## The same bits as the U64. No loss, no error: the whole U64 range maps to the whole I64 range.
	from_u64 : U64 -> Id64
	from_u64 = |n| Id64.{ bits: n.to_i64_wrap() }

	from_i64 : I64 -> Id64
	from_i64 = |n| Id64.{ bits: n }

	## 8 bytes, big-endian (the prefix of a SHA-256). Another length is `Err(BadLength)`.
	from_bytes : List(U8) -> Try(Id64, [BadLength])
	from_bytes = |bytes|
		if bytes.len() == 8 {
			Ok(Id64.from_u64(bytes.fold(0.U64, |acc, b| acc.shl_wrap(8).bitwise_or(b.to_u64()))))
		} else {
			Err(BadLength)
		}

	## Decimal text, canonical (`0`, or `-?[1-9][0-9]*`), as the I64 (-2^63 to 2^63-1) or as the U64 (2^63 to 2^64-1).
	## The two ranges share no text except 0 to 2^63-1, where both mean the same value: there is no ambiguity.
	from_str : Str -> Try(Id64, [BadId])
	from_str = |s| match I64.from_str(s) {
		Ok(n) if n.to_str() == s => Ok(Id64.{ bits: n })
		_ => match U64.from_str(s) {
			Ok(n) if n.to_str() == s => Ok(Id64.from_u64(n))
			_ => Err(BadId)
		}
	}

	to_u64 : Id64 -> U64
	to_u64 = |id| id.bits.to_u64_wrap()

	to_i64 : Id64 -> I64
	to_i64 = |id| id.bits

	## 8 bytes, big-endian.
	to_bytes : Id64 -> List(U8)
	to_bytes = |id| {
		n = id.bits.to_u64_wrap()
		[56, 48, 40, 32, 24, 16, 8, 0].map(|shift| n.shr_zf_wrap(shift).to_u8_wrap())
	}

	## The decimal text of the I64. It is the text that SQL and CBOR use.
	to_str : Id64 -> Str
	to_str = |id| id.bits.to_str()

	## The decimal text of the U64. It is the text that a browser sees (JSON).
	to_u64_str : Id64 -> Str
	to_u64_str = |id| id.bits.to_u64_wrap().to_str()

	## The same id for an API payload: any format writes the U64 text. A field `id : Id64.Web` in a response record.
	to_web : Id64 -> Id64.Web
	to_web = |id| Id64.Web.{ bits: id.bits }

	## Reads the id of an API payload (the same as the parser of `Id64`).
	from_web : Id64.Web -> Id64
	from_web = |Id64.Web.{ bits }| Id64.{ bits }

	is_eq : _

	to_hash : _

	to_inspect : Id64 -> Str
	to_inspect = |id| "Id64(${id.bits.to_str()})"

	## Reads decimal text, or else a CBOR integer (`parse_i64`). The state is a value, so the second try starts at the same item.
	parser_for : encoding -> (state -> Try({ value : Id64, rest : state }, err))
		where [
			encoding.parse_str : encoding, state -> Try({ value : Str, rest : state }, err),
			encoding.parse_i64 : encoding, state -> Try({ value : I64, rest : state }, err),
		]
	parser_for = |encoding| {
		Encoding : encoding

		|state| {
			from_text = match Encoding.parse_str(encoding, state) {
				Ok({ value: text, rest }) => match Id64.from_str(text) {
					Ok(id) => Ok({ value: id, rest })
					Err(BadId) => Err(BadId)
				}
				Err(_) => Err(NotText)
			}
			match from_text {
				Ok(done) => Ok(done)
				# Not text, or bad text: the integer parser reads an integer, or gives the error of the format at this position.
				Err(_) => {
					n = Encoding.parse_i64(encoding, state)?
					Ok({ value: Id64.{ bits: n.value }, rest: n.rest })
				}
			}
		}
	}

	## Writes the decimal text of the I64 (R-IK2). CBOR only (see the marker).
	encoder_for : encoding -> (Id64, state -> Try(state, err))
		where [
			encoding.encode_str : Str, state -> Try(state, err),
			# Marker, never called: only a binary format has it. `Encoding.Json` has no `encode_bytes`, so an `Id64` in a JSON
			# value does not compile: it would show the I64 text (negative above 2^63) to a browser. Use `Id64.Web` there.
			encoding.encode_bytes : List(U8), state -> Try(state, err),
		]
	encoder_for = |_| {
		Encoding : encoding

		|id, state| Encoding.encode_str(id.bits.to_str(), state)
	}

	## An id for a browser: it writes the U64 text in any format (JSON too), and reads the same as `Id64`.
	Web :: { bits : I64 }.{

		is_eq : _

		to_hash : _

		to_inspect : Id64.Web -> Str
		to_inspect = |w| "Id64.Web(${w.bits.to_u64_wrap().to_str()})"

		parser_for : encoding -> (state -> Try({ value : Id64.Web, rest : state }, err))
			where [
				encoding.parse_str : encoding, state -> Try({ value : Str, rest : state }, err),
				encoding.parse_i64 : encoding, state -> Try({ value : I64, rest : state }, err),
			]
		parser_for = |encoding| {
			Encoding : encoding

			read = Id64.parser_for(encoding)
			|state| {
				parsed = read(state)?
				Ok({ value: Id64.to_web(parsed.value), rest: parsed.rest })
			}
		}

		encoder_for : encoding -> (Id64.Web, state -> Try(state, err))
			where [
				encoding.encode_str : Str, state -> Try(state, err),
			]
		encoder_for = |_| {
			Encoding : encoding

			|w, state| Encoding.encode_str(w.bits.to_u64_wrap().to_str(), state)
		}
	}
}
