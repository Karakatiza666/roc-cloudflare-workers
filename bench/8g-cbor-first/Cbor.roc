# PLAN.md 8g research copy of roc-cbor 0.1.0 (Karakatiza666/roc-cbor, 9QL2dCyq...): only `parse_record_field` (and the helpers `find_field`, `same_bytes`/`first_byte`) differ. Never publish it.
# Copyright © 2026 Heorhii Bulakh and subsequent roc-cbor authors <github.com/Karakatiza666/roc-cbor/graphs/contributors>
# Licensed under the Universal Permissive License (UPL), Version 1.0. See LICENSE.

## CBOR (RFC 8949) as a format of the Roc codec protocol. The derived `parser_for` and
## `encoder_for` of a type read and write it, as they do for `Json`.
##
## ```roc
## bytes = Cbor.encode({ name: "x", size: 3.U64 })
## parsed : Try({ name : Str, size : U64 }, _)
## parsed = Cbor.parse(bytes)
## ```
##
## Data model: the same as `Json`. A record is a map with text keys, a tag with no payload is
## text, a tag with payloads is a map of one entry, a list and a tuple are arrays. So a peer
## that reads JSON sees the same objects from this format.
##
## Profile: definite lengths only. Any argument width is read. Integers are major types 0 and 1.
## A float with no fraction also reads as an integer when its size is 2^53 - 1 or less. Floats are f16, f32 or f64 when read, f64
## (F32: f32) when written. `null` and `undefined` both read as `Err(Null)` of a `Try(a, [Null])`.
## A byte string reads as a `List(U8)`. A `List(U8)` writes as an array (the protocol has no bytes hook).
## `Cbor.Bytes` reads and writes a byte string (major type 2).
Cbor :: { fields : [Snake, Camel], int_from_text : Bool }.{

	## The options of `parse_with`.
	##
	## | Field | Value |
	## | --- | --- |
	## | `fields` | `Snake`: a record field `user_id` reads the key `user_id`. `Camel`: it reads the key `userId`. |
	## | `int_from_text` | `Bool.True`: an integer type (`U8` to `I64`) also reads text that is a canonical decimal integer in its range: `0`, or `-?[1-9][0-9]*`. Other text is an error. |
	Options : { fields : [Snake, Camel], int_from_text : Bool }

	## One step of the path that `path_at` gives: an array index or a map key.
	Step : [Index(U64), Key(Str)]

	## The read position of a parse. The derived parsers pass it from step to step. Its fields are hidden.
	State :: { bytes : List(U8), pos : U64, raw : U64 }

	## A type that `Cbor.parse` can read. Use it in the `where` clause of a function that calls
	## `Cbor.parse` with a type variable: `where [a.Cbor.Parseable([InvalidCbor(U64), ..errs])]`.
	a.Parseable(errs) :
		where [
			a.parser_for : Cbor -> (Cbor.State -> Try({ value : a, rest : Cbor.State }, errs)),
		]

	## A type that `Cbor.encode` can write. Use it in the `where` clause of a function that calls
	## `Cbor.encode` with a type variable: `where [a.Cbor.Encodable([])]`.
	a.Encodable(err) :
		where [
			a.encoder_for : Cbor -> (a, List(U8) -> Try(List(U8), err)),
		]

	## Bytes that cross as a CBOR byte string (major type 2). A `List(U8)`
	## writes as an array of numbers, because the derived encoder has no hook for bytes.
	## `Cbor.Bytes.(list)` makes one, and `bytes.to_list()` gives the list back.
	Bytes := List(U8).{

		## Two values are equal when their lists are equal.
		is_eq : _

		## Reads a byte string (major type 2) only. An array of numbers is an error.
		parser_for : encoding -> (state -> Try({ value : Cbor.Bytes, rest : state }, err))
			where [
				encoding.parse_bytes : encoding, state -> Try({ value : List(U8), rest : state }, err),
			]
		parser_for = |encoding| {
			Encoding : encoding

			|state| {
				parsed = Encoding.parse_bytes(encoding, state)?
				Ok({ value: Cbor.Bytes.(parsed.value), rest: parsed.rest })
			}
		}

		## Writes a byte string (major type 2).
		encoder_for : encoding -> (Cbor.Bytes, state -> Try(state, err))
			where [
				encoding.encode_bytes : List(U8), state -> Try(state, err),
			]
		encoder_for = |_| {
			Encoding : encoding

			|Cbor.Bytes.(bytes), state| Encoding.encode_bytes(bytes, state)
		}

		## The bytes as a list.
		to_list : Cbor.Bytes -> List(U8)
		to_list = |Cbor.Bytes.(bytes)| bytes
	}

	## Reads one CBOR item of the type `a` from all of `bytes`. The type comes from the annotation.
	## The error is `InvalidCbor(pos)`, with the byte position of the problem, or
	## `MissingRequiredField(name)` from the derived parser of a record.
	## Bytes after the item are an error at the position of the first extra byte.
	## The same as `parse_with(bytes, { fields: Snake, int_from_text: Bool.False })`.
	parse : List(U8) -> Try(a, [InvalidCbor(U64), ..errs]) where [a.Parseable([InvalidCbor(U64), ..errs])]
	parse = |bytes| Cbor.parse_with(bytes, { fields: Snake, int_from_text: Bool.False })

	## Like `parse`, with record fields in camelCase: `user_id` is read from `userId`.
	## The same as `parse_with(bytes, { fields: Camel, int_from_text: Bool.False })`.
	parse_camel : List(U8) -> Try(a, [InvalidCbor(U64), ..errs]) where [a.Parseable([InvalidCbor(U64), ..errs])]
	parse_camel = |bytes| Cbor.parse_with(bytes, { fields: Camel, int_from_text: Bool.False })

	## Like `parse`, with options (`Cbor.Options`).
	##
	## ```roc
	## id : Try(I64, _)
	## id = Cbor.parse_with(bytes, { fields: Snake, int_from_text: Bool.True })
	## ```
	parse_with : List(U8), Cbor.Options -> Try(a, [InvalidCbor(U64), ..errs]) where [a.Parseable([InvalidCbor(U64), ..errs])]
	parse_with = |bytes, options| {
		Shape : a
		parse_shape = Shape.parser_for(Cbor.{ fields: options.fields, int_from_text: options.int_from_text })
		parsed = parse_shape(Cbor.State.{ bytes, pos: 0, raw: 0 })?
		if (parsed.rest.pos == bytes.len()) Ok(parsed.value) else Err(InvalidCbor(parsed.rest.pos))
	}

	## The path from the root to the item that starts at `pos`: the array indexes and the map keys.
	## Use it with the position of `InvalidCbor(pos)` to find the field of the error.
	## The path of the root is `[]`. `Err(NotFound)` when no item starts at `pos` (also a map key,
	## or a position in the middle of an item), or when the bytes before `pos` are not valid.
	##
	## ```roc
	## # [{"name": "a", "id": 1.5}]: the value of "id" starts at 12
	## expect Cbor.path_at(bytes, 12) == Ok([Index(0), Key("id")])
	## ```
	path_at : List(U8), U64 -> Try(List(Cbor.Step), [NotFound])
	path_at = |bytes, pos| path_to(Cbor.State.{ bytes, pos: 0, raw: 0 }, pos)

	## Writes `value` as one CBOR item. It cannot fail.
	encode : a -> List(U8) where [a.Encodable([])]
	encode = |value| {
		Shape : a
		encode_shape = Shape.encoder_for(Cbor.{ fields: Snake, int_from_text: Bool.False })
		match encode_shape(value, List.with_capacity(256)) {
			Ok(out) => out
		}
	}

	## Codec protocol: the record field name to look for. `Camel` gives the camelCase name.
	rename_field : Cbor, Str -> Str
	rename_field = |encoding, name|
		match encoding {
			{ fields: Snake, int_from_text: _ } => name
			{ fields: Camel, int_from_text: _ } => Json.snake_to_camel(name)
		}

	## Codec protocol: the error for a value that does not fit its type.
	invalid_value : Cbor, Cbor.State -> [InvalidCbor(U64)]
	invalid_value = |_, state| InvalidCbor(state.pos)

	# Scalars

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_str : Cbor, Cbor.State -> Try({ value : Str, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_str = |_, state| text(state)

	## A byte string (major type 2) only. `Cbor.Bytes` calls it.
	parse_bytes : Cbor, Cbor.State -> Try({ value : List(U8), rest : Cbor.State }, [InvalidCbor(U64)])
	parse_bytes = |_, state| {
		h = head(state)?
		if h.major != 2 or h.arg > state.bytes.len() - h.next {
			return Err(InvalidCbor(state.pos))
		}
		Ok({ value: state.bytes.sublist({ start: h.next, len: h.arg }), rest: at(state, h.next + h.arg) })
	}

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_bool : Cbor, Cbor.State -> Try({ value : Bool, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_bool = |_, state|
		match if (state.raw > 0) Err(OutOfBounds) else state.bytes.get(state.pos) {
			Ok(0xf4) => Ok({ value: Bool.False, rest: at(state, state.pos + 1) })
			Ok(0xf5) => Ok({ value: Bool.True, rest: at(state, state.pos + 1) })
			_ => Err(InvalidCbor(state.pos))
		}

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_null : Cbor, Cbor.State -> Try(Cbor.State, [InvalidCbor(U64)])
	parse_null = |_, state|
		match if (state.raw > 0) Err(OutOfBounds) else state.bytes.get(state.pos) {
			Ok(0xf6) | Ok(0xf7) => Ok(at(state, state.pos + 1))
			_ => Err(InvalidCbor(state.pos))
		}

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_u8 : Cbor, Cbor.State -> Try({ value : U8, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_u8 = |cbor, state|
		if state.raw > 0 {
			# An item of a byte string read as a List(U8).
			b = state.bytes.get(state.pos) ? |_| InvalidCbor(state.pos)
			Ok({ value: b, rest: Cbor.State.{ bytes: state.bytes, pos: state.pos + 1, raw: state.raw - 1 } })
		} else {
			n = int(cbor, state)?
			v = n.value.to_u8_try() ? |_| InvalidCbor(state.pos)
			Ok({ value: v, rest: n.rest })
		}

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_u16 : Cbor, Cbor.State -> Try({ value : U16, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_u16 = |cbor, state| {
		n = int(cbor, state)?
		Ok({ value: n.value.to_u16_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_u32 : Cbor, Cbor.State -> Try({ value : U32, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_u32 = |cbor, state| {
		n = int(cbor, state)?
		Ok({ value: n.value.to_u32_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_u64 : Cbor, Cbor.State -> Try({ value : U64, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_u64 = |cbor, state| {
		n = int(cbor, state)?
		Ok({ value: n.value.to_u64_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_i8 : Cbor, Cbor.State -> Try({ value : I8, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_i8 = |cbor, state| {
		n = int(cbor, state)?
		Ok({ value: n.value.to_i8_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_i16 : Cbor, Cbor.State -> Try({ value : I16, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_i16 = |cbor, state| {
		n = int(cbor, state)?
		Ok({ value: n.value.to_i16_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_i32 : Cbor, Cbor.State -> Try({ value : I32, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_i32 = |cbor, state| {
		n = int(cbor, state)?
		Ok({ value: n.value.to_i32_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_i64 : Cbor, Cbor.State -> Try({ value : I64, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_i64 = |cbor, state| {
		n = int(cbor, state)?
		Ok({ value: n.value.to_i64_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_f64 : Cbor, Cbor.State -> Try({ value : F64, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_f64 = |_, state| float(state)

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_f32 : Cbor, Cbor.State -> Try({ value : F32, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_f32 = |_, state| {
		f = float(state)?
		# A finite value outside the F32 range is an error, not an infinity.
		if f.value.is_finite() and f.value.abs() > F32.highest.to_f64() {
			Err(InvalidCbor(state.pos))
		} else {
			Ok({ value: f.value.to_f32_wrap(), rest: f.rest })
		}
	}

	# Containers

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_list_start : Cbor, Cbor.State -> Try([Counted({ len : U64, rest : Cbor.State }), Uncounted(Cbor.State)], [InvalidCbor(U64)])
	parse_list_start = |_, state| {
		h = head(state)?
		if h.arg > state.bytes.len() - h.next {
			# Each item is 1 byte or more: a count that does not fit is an error, not an allocation.
			return Err(InvalidCbor(state.pos))
		}
		match h.major {
			4 => Ok(Counted({ len: h.arg, rest: at(state, h.next) }))
			2 => Ok(Counted({ len: h.arg, rest: Cbor.State.{ bytes: state.bytes, pos: h.next, raw: h.arg } }))
			_ => Err(InvalidCbor(state.pos))
		}
	}

	## Not called: each list is counted.
	parse_list_next : Cbor, Cbor.State -> Try([Item(Cbor.State), Done(Cbor.State)], [InvalidCbor(U64)])
	parse_list_next = |_, state| Err(InvalidCbor(state.pos))

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_list_after_item : Cbor, Cbor.State -> Try([Continue(Cbor.State), Done(Cbor.State)], [InvalidCbor(U64)])
	parse_list_after_item = |_, state| Err(InvalidCbor(state.pos))

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_tuple_start : Cbor, Cbor.State, U64 -> Try(Cbor.State, [InvalidCbor(U64)])
	parse_tuple_start = |_, state, len| {
		h = head(state)?
		if (h.major == 4 and h.arg == len) Ok(at(state, h.next)) else Err(InvalidCbor(state.pos))
	}

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_tuple_next : Cbor, Cbor.State, U64, U64 -> Try(Cbor.State, [InvalidCbor(U64)])
	parse_tuple_next = |_, state, _, _| Ok(state)

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_tuple_end : Cbor, Cbor.State, U64 -> Try(Cbor.State, [InvalidCbor(U64)])
	parse_tuple_end = |_, state, _| Ok(state)

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_record_start : Cbor, Cbor.State -> Try([Counted({ len : U64, rest : Cbor.State }), Uncounted(Cbor.State)], [InvalidCbor(U64)])
	parse_record_start = |_, state| {
		h = head(state)?
		# Each entry is 2 bytes or more.
		if h.major == 5 and h.arg <= (state.bytes.len() - h.next) // 2 {
			Ok(Counted({ len: h.arg, rest: at(state, h.next) }))
		} else {
			Err(InvalidCbor(state.pos))
		}
	}

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_record_field : Cbor,
	Encoding.FieldName.FieldNames(_shape),
	Cbor.State -> Try(
		[
			Field({ field : Encoding.FieldName(_shape), rest : Cbor.State }),
			TryField({ name : Str, rest : Cbor.State }),
			TryFieldCaseless({ name : Str, rest : Cbor.State }),
			Continue(Cbor.State),
			Done(Cbor.State),
		],
		[InvalidCbor(U64)],
	)
	parse_record_field = |_, names, state| {
		# 8g variant: the key is not made into a `Str`. The bytes of the key are compared with the names of the fields of
		# the same length. A key that is no field of the type is a `TryField` (the derived parser skips it).
		h = head(state)?
		if h.major != 3 or h.arg > state.bytes.len() - h.next {
			return Err(InvalidCbor(state.pos))
		}
		key = state.bytes.sublist({ start: h.next, len: h.arg })
		rest = at(state, h.next + h.arg)
		# NOT CORRECT, a bound for the measure: the first field of the same length with the same first byte, no compare of
		# the other bytes (a key that differs later is taken for it).
		first = key.first() ?? 0
		found = find_field(names, h.arg, first)
		match found {
			Ok(f) => Ok(Field({ field: f, rest }))
			Err(_) => {
				name = Str.from_utf8(key) ? |_| InvalidCbor(state.pos)
				Ok(TryField({ name, rest }))
			}
		}
	}

	## Not called: each map is counted.
	parse_record_after_field : Cbor, Cbor.State -> Try([Continue(Cbor.State), Done(Cbor.State)], [InvalidCbor(U64)])
	parse_record_after_field = |_, state| Err(InvalidCbor(state.pos))

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	skip_record_field : Cbor, Cbor.State -> Try(Cbor.State, [InvalidCbor(U64)])
	skip_record_field = |_, state| skip(state)

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_dict_start : Cbor, Cbor.State -> Try([Counted({ len : U64, rest : Cbor.State }), Uncounted(Cbor.State)], [InvalidCbor(U64)])
	parse_dict_start = |encoding, state| parse_record_start(encoding, state)

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_dict_next : Cbor, Cbor.State -> Try([Entry(Cbor.State), Done(Cbor.State)], [InvalidCbor(U64)])
	parse_dict_next = |_, state| Err(InvalidCbor(state.pos))

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_dict_after_key : Cbor, Cbor.State -> Try(Cbor.State, [InvalidCbor(U64)])
	parse_dict_after_key = |_, state| Ok(state)

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_dict_after_entry : Cbor, Cbor.State -> Try([Continue(Cbor.State), Done(Cbor.State)], [InvalidCbor(U64)])
	parse_dict_after_entry = |_, state| Err(InvalidCbor(state.pos))

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_key_start : Cbor, Cbor.State -> Try(Cbor.State, [InvalidCbor(U64)])
	parse_key_start = |_, state| Ok(state)

	## Codec protocol: the derived `parser_for` of a type calls it. An app calls `Cbor.parse`.
	parse_key_str : Cbor, Cbor.State -> Try({ value : Str, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_key_str = |_, state| text(state)

	## Text: a tag with no payload. A map of one entry: the tag, then its payload, or an
	## array of its payloads when it has more than one. The same shapes as `Json`.
	parse_tag_union : Cbor, Encoding.ParseTagUnionSpec(a), Cbor.State -> Try({ value : a, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_tag_union = |encoding, spec, state| {
		h = head(state)?
		match h.major {
			3 => {
				name = text(state)?
				Encoding.ParseTagUnionSpec.parse(
					spec,
					{
						tag: name.value,
						encoding,
						state: name.rest,
						start_payloads: |s, count| if (count == 0) Ok(s) else Err(InvalidCbor(s.pos)),
						next_payload: |s, _, _| Err(InvalidCbor(s.pos)),
						finish_payloads: |s, _| Ok(s),
						missing: InvalidCbor(state.pos),
					},
				)
			}
			5 if h.arg == 1 => {
				name = text(at(state, h.next))?
				Encoding.ParseTagUnionSpec.parse(
					spec,
					{
						tag: name.value,
						encoding,
						state: name.rest,
						start_payloads: |s, count|
							if count == 1 {
								Ok(s)
							} else {
								t = head(s)?
								if (t.major == 4 and t.arg == count) Ok(at(s, t.next)) else Err(InvalidCbor(s.pos))
							},
						next_payload: |s, _, _| Ok(s),
						finish_payloads: |s, _| Ok(s),
						missing: InvalidCbor(state.pos),
					},
				)
			}
			_ => Err(InvalidCbor(state.pos))
		}
	}

	# Encode. A container header gets the width of the declared count, and the module writes
	# the real count at the end: an absent optional field makes a record smaller.

	## Codec protocol: the derived `encoder_for` of a type calls it. An app calls `Cbor.encode`.
	encode_str : Str, List(U8) -> Try(List(U8), [])
	encode_str = |value, out| Ok(put_text(out, value))

	## A byte string (major type 2). `Cbor.Bytes` calls it.
	encode_bytes : List(U8), List(U8) -> Try(List(U8), [])
	encode_bytes = |value, out| Ok(put_head(out, 2, value.len()).concat(value))

	## Codec protocol: the derived `encoder_for` of a type calls it. An app calls `Cbor.encode`.
	encode_bool : Bool, List(U8) -> Try(List(U8), [])
	encode_bool = |value, out| Ok(out.append(if (value) 0xf5 else 0xf4))

	## Codec protocol: the derived `encoder_for` of a type calls it. An app calls `Cbor.encode`.
	encode_null : List(U8) -> Try(List(U8), [])
	encode_null = |out| Ok(out.append(0xf6))

	## Codec protocol: the derived `encoder_for` of a type calls it. An app calls `Cbor.encode`.
	encode_u8 : U8, List(U8) -> Try(List(U8), [])
	encode_u8 = |value, out| Ok(put_head(out, 0, value.to_u64()))

	## Codec protocol: the derived `encoder_for` of a type calls it. An app calls `Cbor.encode`.
	encode_u16 : U16, List(U8) -> Try(List(U8), [])
	encode_u16 = |value, out| Ok(put_head(out, 0, value.to_u64()))

	## Codec protocol: the derived `encoder_for` of a type calls it. An app calls `Cbor.encode`.
	encode_u32 : U32, List(U8) -> Try(List(U8), [])
	encode_u32 = |value, out| Ok(put_head(out, 0, value.to_u64()))

	## Codec protocol: the derived `encoder_for` of a type calls it. An app calls `Cbor.encode`.
	encode_u64 : U64, List(U8) -> Try(List(U8), [])
	encode_u64 = |value, out| Ok(put_head(out, 0, value))

	## Codec protocol: the derived `encoder_for` of a type calls it. An app calls `Cbor.encode`.
	encode_i8 : I8, List(U8) -> Try(List(U8), [])
	encode_i8 = |value, out| Ok(put_int(out, value.to_i64()))

	## Codec protocol: the derived `encoder_for` of a type calls it. An app calls `Cbor.encode`.
	encode_i16 : I16, List(U8) -> Try(List(U8), [])
	encode_i16 = |value, out| Ok(put_int(out, value.to_i64()))

	## Codec protocol: the derived `encoder_for` of a type calls it. An app calls `Cbor.encode`.
	encode_i32 : I32, List(U8) -> Try(List(U8), [])
	encode_i32 = |value, out| Ok(put_int(out, value.to_i64()))

	## Codec protocol: the derived `encoder_for` of a type calls it. An app calls `Cbor.encode`.
	encode_i64 : I64, List(U8) -> Try(List(U8), [])
	encode_i64 = |value, out| Ok(put_int(out, value))

	## Codec protocol: the derived `encoder_for` of a type calls it. An app calls `Cbor.encode`.
	encode_f64 : F64, List(U8) -> Try(List(U8), [])
	encode_f64 = |value, out| Ok(put_be(out.append(0xfb), value.to_bits(), 8))

	## Codec protocol: the derived `encoder_for` of a type calls it. An app calls `Cbor.encode`.
	encode_f32 : F32, List(U8) -> Try(List(U8), [])
	encode_f32 = |value, out| Ok(put_be(out.append(0xfa), value.to_bits().to_u64(), 4))

	## Codec protocol: the derived `encoder_for` of a type calls it. An app calls `Cbor.encode`.
	encode_record : List(U8), U64, ({ out : List(U8), n : U64 }, ({ out : List(U8), n : U64 }, Str, (List(U8) -> Try(List(U8), err)) -> Try({ out : List(U8), n : U64 }, err)) -> Try({ out : List(U8), n : U64 }, err)) -> Try(List(U8), err)
	encode_record = |out, count, write_fields| {
		start = out.len()
		done = write_fields(
			{ out: put_head_wide(out, 5, count), n: 0 },
			|c, name, write_value| {
				Ok({ out: write_value(put_text(c.out, name))?, n: c.n + 1 })
			},
		)?
		Ok(patch_count(done.out, start, done.n))
	}

	## Codec protocol: the derived `encoder_for` of a type calls it. An app calls `Cbor.encode`.
	encode_list : List(U8), U64, ({ out : List(U8), n : U64 }, ({ out : List(U8), n : U64 }, (List(U8) -> Try(List(U8), err)) -> Try({ out : List(U8), n : U64 }, err)) -> Try({ out : List(U8), n : U64 }, err)) -> Try(List(U8), err)
	encode_list = |out, count, write_items| {
		start = out.len()
		done = write_items(
			{ out: put_head_wide(out, 4, count), n: 0 },
			|c, write_value| Ok({ out: write_value(c.out)?, n: c.n + 1 }),
		)?
		Ok(patch_count(done.out, start, done.n))
	}

	## Codec protocol: the derived `encoder_for` of a type calls it. An app calls `Cbor.encode`.
	encode_tuple : List(U8), U64, ({ out : List(U8), n : U64 }, ({ out : List(U8), n : U64 }, (List(U8) -> Try(List(U8), err)) -> Try({ out : List(U8), n : U64 }, err)) -> Try({ out : List(U8), n : U64 }, err)) -> Try(List(U8), err)
	encode_tuple = |out, count, write_items| Cbor.encode_list(out, count, write_items)

	## Codec protocol: the derived `encoder_for` of a type calls it. An app calls `Cbor.encode`.
	encode_tag : List(U8), Str, U64, ({ out : List(U8), n : U64 }, ({ out : List(U8), n : U64 }, (List(U8) -> Try(List(U8), err)) -> Try({ out : List(U8), n : U64 }, err)) -> Try({ out : List(U8), n : U64 }, err)) -> Try(List(U8), err)
	encode_tag = |out, tag, count, write_payloads|
		if count == 0 {
			Ok(put_text(out, tag))
		} else {
			keyed = put_text(put_head(out, 5, 1), tag)
			if count == 1 {
				done = write_payloads({ out: keyed, n: 0 }, |c, write_value| Ok({ out: write_value(c.out)?, n: c.n + 1 }))?
				Ok(done.out)
			} else {
				Cbor.encode_list(keyed, count, write_payloads)
			}
		}
}

first_byte : Str -> U8
first_byte = |name| match name.iter_utf8().next() {
	One({ item, rest: _ }) => item
	_ => 0
}

find_field : Encoding.FieldName.FieldNames(_shape), U64, U8 -> Try(Encoding.FieldName(_shape), [NoField])
find_field = |names, len, first| {
	for f in names.for_size(len) {
		if first_byte(f.name()) == first {
			return Ok(f)
		}
	}
	Err(NoField)
}

at : Cbor.State, U64 -> Cbor.State
at = |state, pos| Cbor.State.{ bytes: state.bytes, pos, raw: 0 }

## The initial byte and its argument (RFC 8949 3). Indefinite lengths and the reserved
## values 28 to 30 are errors in this profile.
head : Cbor.State -> Try({ major : U8, arg : U64, next : U64 }, [InvalidCbor(U64)])
head = |state| {
	p = state.pos
	if state.raw > 0 {
		# An item of a byte string is a U8 only (parse_u8), never the head of an item.
		return Err(InvalidCbor(p))
	}
	b = state.bytes.get(p) ? |_| InvalidCbor(p)
	major = b.shr_zf_wrap(5)
	info = b.bitwise_and(31)
	if info < 24 {
		Ok({ major, arg: info.to_u64(), next: p + 1 })
	} else {
		size = match info {
			24 => 1
			25 => 2
			26 => 4
			27 => 8
			_ => 0
		}
		if size == 0 or p + 1 + size > state.bytes.len() {
			Err(InvalidCbor(p))
		} else {
			Ok({ major, arg: get_be(state.bytes, p + 1, size), next: p + 1 + size })
		}
	}
}

get_be : List(U8), U64, U64 -> U64
get_be = |bytes, start, size| {
	var $n = 0.U64
	for i in (0.U64).until(size) {
		$n = $n.shl_wrap(8).bitwise_or((bytes.get(start + i) ?? 0).to_u64())
	}
	$n
}

text : Cbor.State -> Try({ value : Str, rest : Cbor.State }, [InvalidCbor(U64)])
text = |state| {
	h = head(state)?
	if h.major != 3 or h.arg > state.bytes.len() - h.next {
		return Err(InvalidCbor(state.pos))
	}
	value = Str.from_utf8(state.bytes.sublist({ start: h.next, len: h.arg })) ? |_| InvalidCbor(state.pos)
	Ok({ value, rest: at(state, h.next + h.arg) })
}

## An integer of major type 0 or 1, as I128 so that both u64 and -2^64 fit.
## A float with no fraction is also read when its size is 2^53 - 1 or less (a JS Number).
## A larger float can be the rounded value of many integers, so it is an error.
## With `int_from_text`, text that is a canonical decimal integer is also read.
int : Cbor, Cbor.State -> Try({ value : I128, rest : Cbor.State }, [InvalidCbor(U64)])
int = |cbor, state| {
	h = head(state)?
	match (h.major, cbor) {
		(0, _) => Ok({ value: h.arg.to_i128(), rest: at(state, h.next) })
		(1, _) => Ok({ value: -1 - h.arg.to_i128(), rest: at(state, h.next) })
		(3, { fields: _, int_from_text: Bool.True }) => {
			t = text(state)?
			i = decimal(t.value) ? |_| InvalidCbor(state.pos)
			Ok({ value: i, rest: t.rest })
		}
		(7, _) => {
			f = float(state)?
			i = f.value.to_i128_try() ? |_| InvalidCbor(state.pos)
			safe = 9_007_199_254_740_991
			if i.to_f64() == f.value and i <= safe and i >= -safe {
				Ok({ value: i, rest: f.rest })
			} else {
				Err(InvalidCbor(state.pos))
			}
		}
		_ => Err(InvalidCbor(state.pos))
	}
}

## A canonical decimal integer: `0`, or an optional `-`, a digit 1 to 9, then digits.
## At most 20 digits, so the value fits an I128. The caller checks the range of its type.
decimal : Str -> Try(I128, [NotDecimal])
decimal = |s| {
	bytes = s.to_utf8()
	(neg, digits) =
		match bytes {
			['-', .. as rest] => (Bool.True, rest)
			_ => (Bool.False, bytes)
		}
	ok =
		match digits {
			['0'] => !neg
			[first, ..] => first >= '1' and first <= '9' and digits.len() <= 20 and digits.all(|d| d >= '0' and d <= '9')
			[] => Bool.False
		}
	if ok {
		n = digits.fold(0.I128, |acc, d| acc * 10 + (d - '0').to_i128())
		Ok(if (neg) -n else n)
	} else {
		Err(NotDecimal)
	}
}

float : Cbor.State -> Try({ value : F64, rest : Cbor.State }, [InvalidCbor(U64)])
float = |state| {
	h = head(state)?
	match (h.major, state.bytes.get(state.pos) ?? 0) {
		(0, _) => Ok({ value: h.arg.to_f64(), rest: at(state, h.next) })
		(1, _) => Ok({ value: -1.0 - h.arg.to_f64(), rest: at(state, h.next) })
		(7, 0xfb) => Ok({ value: F64.from_bits(h.arg), rest: at(state, h.next) })
		(7, 0xfa) => Ok({ value: F32.from_bits(h.arg.to_u32_wrap()).to_f64(), rest: at(state, h.next) })
		(7, 0xf9) => Ok({ value: half(h.arg), rest: at(state, h.next) })
		_ => Err(InvalidCbor(state.pos))
	}
}

## IEEE 754 binary16 (RFC 8949 Appendix D).
half : U64 -> F64
half = |h| {
	exp = h.shr_zf_wrap(10).bitwise_and(0x1f)
	mant = h.bitwise_and(0x3ff).to_f64()
	value =
		if exp == 0 {
			mant * 0.000000059604644775390625 # 2^-24
		} else if exp != 31 {
			(mant + 1024.0) * pow2(exp.to_i64_wrap() - 25)
		} else if mant == 0.0 {
			F64.infinity
		} else {
			F64.nan
		}
	if (h.bitwise_and(0x8000) != 0) -value else value
}

pow2 : I64 -> F64
pow2 = |e| {
	var $v = 1.0.F64
	if e >= 0 {
		for _ in (0.I64).until(e) {
			$v = $v * 2.0
		}
	} else {
		for _ in (0.I64).until(-e) {
			$v = $v / 2.0
		}
	}
	$v
}

## Skip one whole item: an unknown record field. A loop with a count of the items to skip,
## not a recursion, so deep nesting does not overflow the stack.
skip : Cbor.State -> Try(Cbor.State, [InvalidCbor(U64)])
skip = |state| {
	var $s = state
	var $todo = 1.U64
	while $todo > 0 {
		h = head($s)?
		room = $s.bytes.len() - h.next
		if ((h.major == 2 or h.major == 3 or h.major == 4) and h.arg > room) or (h.major == 5 and h.arg > room // 2) {
			return Err(InvalidCbor($s.pos))
		}
		next = if (h.major == 2 or h.major == 3) h.next + h.arg else h.next
		more =
			match h.major {
				4 => h.arg
				5 => h.arg * 2
				6 => 1 # a tag, then one item
				_ => 0
			}
		# Each item to skip is 1 byte or more, so `$todo` stays below the length.
		left = $s.bytes.len() - next
		if more > left or $todo - 1 > left - more {
			return Err(InvalidCbor($s.pos))
		}
		$s = at($s, next)
		$todo = $todo - 1 + more
	}
	Ok($s)
}

## The path to the item that starts at `pos` (see `path_at`). One pass over the items, with a
## loop and a list of the open containers, not a recursion. The bounds are the bounds of `skip`.
path_to : Cbor.State, U64 -> Try(List(Cbor.Step), [NotFound])
path_to = |state, pos| {
	var $s = state
	# One entry for each open array or map: is it a map, the items left, the index of the next item.
	var $open = []
	# One step for each open container that has an item in progress.
	var $path = []
	while $s.pos <= pos {
		# Here $s is at the start of an item, and $path is the path of that item.
		if $s.pos == pos {
			return Ok($path)
		}
		h = head($s) ? |_| NotFound
		room = $s.bytes.len() - h.next
		if ((h.major == 2 or h.major == 3 or h.major == 4) and h.arg > room) or (h.major == 5 and h.arg > room // 2) {
			return Err(NotFound)
		}
		if h.major == 6 {
			# A tag: its item follows, with the same path.
			$s = at($s, h.next)
		} else {
			if h.major == 4 or h.major == 5 {
				$open = $open.append({ map: h.major == 5, left: h.arg, index: 0 })
				$s = at($s, h.next)
			} else {
				$s = at($s, if (h.major == 2 or h.major == 3) h.next + h.arg else h.next)
			}
			# Go to the start of the next item. Close each container that has no items left.
			var $next = Bool.False
			while !$next {
				top = $open.last() ? |_| NotFound
				if top.index > 0 {
					$path = $path.drop_last(1)
				}
				if top.left == 0 {
					$open = $open.drop_last(1)
				} else {
					step =
						if top.map {
							k = text($s) ? |_| NotFound
							$s = k.rest
							Key(k.value)
						} else {
							Index(top.index)
						}
					$open = $open.drop_last(1).append({ map: top.map, left: top.left - 1, index: top.index + 1 })
					$path = $path.append(step)
					$next = Bool.True
				}
			}
		}
	}
	Err(NotFound)
}

put_head : List(U8), U8, U64 -> List(U8)
put_head = |out, major, n| {
	m = major.shl_wrap(5)
	if n < 24 {
		out.append(m.bitwise_or(n.to_u8_wrap()))
	} else if n < 0x100 {
		out.append(m.bitwise_or(24)).append(n.to_u8_wrap())
	} else if n < 0x10000 {
		put_be(out.append(m.bitwise_or(25)), n, 2)
	} else if n < 0x100000000 {
		put_be(out.append(m.bitwise_or(26)), n, 4)
	} else {
		put_be(out.append(m.bitwise_or(27)), n, 8)
	}
}

## A container head with room for `n`: 1 byte for 23 or less, else 3 or 5 bytes.
put_head_wide : List(U8), U8, U64 -> List(U8)
put_head_wide = |out, major, n| {
	m = major.shl_wrap(5)
	if n < 24 {
		out.append(m.bitwise_or(n.to_u8_wrap()))
	} else if n < 0x10000 {
		put_be(out.append(m.bitwise_or(25)), n, 2)
	} else {
		put_be(out.append(m.bitwise_or(26)), n, 4)
	}
}

## Write the real count into the head that `put_head_wide` wrote at `start`.
patch_count : List(U8), U64, U64 -> List(U8)
patch_count = |out, start, n| {
	b = out.get(start) ?? 0
	match b.bitwise_and(31) {
		25 => set_be(out, start + 1, n, 2)
		26 => set_be(out, start + 1, n, 4)
		_ => out.set(start, b.bitwise_and(0xe0).bitwise_or(n.to_u8_wrap())) ?? out
	}
}

set_be : List(U8), U64, U64, U64 -> List(U8)
set_be = |out, start, n, size| {
	var $o = out
	for i in (0.U64).until(size) {
		$o = $o.set(start + i, n.shr_zf_wrap((8 * (size - 1 - i)).to_u8_wrap()).to_u8_wrap()) ?? $o
	}
	$o
}

## A text head, then the bytes of the text, with no copy of the text into a new list.
put_text : List(U8), Str -> List(U8)
put_text = |out, s| Json.append_json_string_bytes(put_head(out, 3, s.count_utf8_bytes()), s)

put_int : List(U8), I64 -> List(U8)
put_int = |out, i|
	if i >= 0 {
		put_head(out, 0, i.to_u64_wrap())
	} else {
		put_head(out, 1, (-1 - i).to_u64_wrap())
	}

put_be : List(U8), U64, U64 -> List(U8)
put_be = |out, n, size| {
	var $o = out
	for i in (0.U64).until(size) {
		$o = $o.append(n.shr_zf_wrap((8 * (size - 1 - i)).to_u8_wrap()).to_u8_wrap())
	}
	$o
}

# RFC 8949 Appendix A vectors (the part in this profile)

expect Cbor.encode(0.U64) == [0x00]
expect Cbor.encode(23.U64) == [0x17]
expect Cbor.encode(24.U64) == [0x18, 0x18]
expect Cbor.encode(1000.U64) == [0x19, 0x03, 0xe8]
expect Cbor.encode(1000000.U64) == [0x1a, 0x00, 0x0f, 0x42, 0x40]
expect Cbor.encode(18446744073709551615.U64) == [0x1b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
expect Cbor.encode(-1.I64) == [0x20]
expect Cbor.encode(-1000.I64) == [0x39, 0x03, 0xe7]
expect Cbor.encode(1.1.F64) == [0xfb, 0x3f, 0xf1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9a]
expect Cbor.encode(Bool.True) == [0xf5]
expect Cbor.encode("IETF") == [0x64, 0x49, 0x45, 0x54, 0x46]
expect Cbor.encode("\u(fc)") == [0x62, 0xc3, 0xbc]
expect Cbor.encode([1.U64, 2, 3]) == [0x83, 0x01, 0x02, 0x03]
expect Cbor.encode({ a: 1.U64, b: [2.U64, 3] }) == [0xa2, 0x61, 0x61, 0x01, 0x61, 0x62, 0x82, 0x02, 0x03]

expect {
	r : Try(U64, _)
	r = Cbor.parse([0x1b, 0x00, 0x00, 0x00, 0xe8, 0xd4, 0xa5, 0x10, 0x00])
	r == Ok(1000000000000)
}

expect {
	r : Try(I64, _)
	r = Cbor.parse([0x38, 0x63])
	r == Ok(-100)
}

## Half floats: 1.5, 65504.0, 5.960464477539063e-8, -4.0
expect {
	r : Try(List(F64), _)
	r = Cbor.parse([0x84, 0xf9, 0x3e, 0x00, 0xf9, 0x7b, 0xff, 0xf9, 0x00, 0x01, 0xf9, 0xc4, 0x00])
	r == Ok([1.5, 65504.0, 0.00000005960464477539063, -4.0])
}

expect {
	r : Try(F64, _)
	r = Cbor.parse([0xfa, 0x47, 0xc3, 0x50, 0x00])
	r == Ok(100000.0)
}

## A byte string as a List(U8) (h'01020304')
expect {
	r : Try(List(U8), _)
	r = Cbor.parse([0x44, 0x01, 0x02, 0x03, 0x04])
	r == Ok([1, 2, 3, 4])
}

## Indefinite lengths are not in the profile: [_ 1, 2]
expect {
	r : Try(List(U64), _)
	r = Cbor.parse([0x9f, 0x01, 0x02, 0xff])
	r == Err(InvalidCbor(0))
}

# Records, tags, optional fields

Pkg : { name : Str, version : Str, size : U64, tags : List(Str), yanked : Bool }

expect {
	p : Pkg
	p = { name: "roc-lang/http", version: "2.0.0", size: 51385, tags: ["http", "web"], yanked: Bool.False }
	parsed : Try(Pkg, _)
	parsed = Cbor.parse(Cbor.encode(p))
	parsed == Ok(p)
}

## An unknown field is skipped, and a missing optional field is absent.
expect {
	bytes = Cbor.encode({ extra: { deep: [1.U64, 2] }, name: "x" })
	r : Try({ name : Str, nick : Try(Str, [Missing]) }, _)
	r = Cbor.parse(bytes)
	r == Ok({ name: "x", nick: Err(Missing) })
}

expect {
	r : Try({ name : Str, age : U64 }, _)
	r = Cbor.parse(Cbor.encode({ name: "x" }))
	r == Err(MissingRequiredField("age"))
}

## Only the fields that are there count: the head says 1, not 2.
expect {
	v : { count : U64, label ?: Str }
	v = { count: 5 }
	Cbor.encode(v) == [0xa1, 0x65, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x05]
}

Shape : [Circle(F64), Rect(F64, F64), Empty]

expect {
	shapes : List(Shape)
	shapes = [Circle(1.5), Rect(2.0, 3.0), Empty]
	parsed : Try(List(Shape), _)
	parsed = Cbor.parse(Cbor.encode(shapes))
	parsed == Ok(shapes)
}

## The same shapes as Json: {"Circle": 1.5} and "Empty"
expect Cbor.encode(Empty) == [0x65, 0x45, 0x6d, 0x70, 0x74, 0x79]

expect {
	r : Try({ user_id : U64 }, _)
	r = Cbor.parse_camel([0xa1, 0x66, 0x75, 0x73, 0x65, 0x72, 0x49, 0x64, 0x07])
	r == Ok({ user_id: 7 })
}

## A long list: the head has room for the real count.
expect {
	xs : List(U64)
	xs = (0.U64).until(300).collect()
	parsed : Try(List(U64), _)
	parsed = Cbor.parse(Cbor.encode(xs))
	parsed == Ok(xs)
}

## Cbor.Bytes writes a byte string (h'010203'), not an array of numbers.
expect Cbor.encode(Cbor.Bytes.([1, 2, 3])) == [0x43, 0x01, 0x02, 0x03]

## A List(U8) still writes an array.
expect Cbor.encode([1.U8, 2, 3]) == [0x83, 0x01, 0x02, 0x03]

## Cbor.Bytes reads a byte string, also as a record field, and round trips.
expect {
	v : { id : U64, data : Cbor.Bytes }
	v = { id: 7, data: Cbor.Bytes.([0, 255, 16]) }
	parsed : Try({ id : U64, data : Cbor.Bytes }, _)
	parsed = Cbor.parse(Cbor.encode(v))
	parsed == Ok(v)
}

## Cbor.Bytes reads only a byte string: an array of numbers is an error.
expect {
	r : Try(Cbor.Bytes, _)
	r = Cbor.parse([0x83, 0x01, 0x02, 0x03])
	r == Err(InvalidCbor(0))
}

## A head of width 24: 24 bytes or more.
expect {
	b = (0.U8).until(30).collect()
	Cbor.encode(Cbor.Bytes.(b)).take_first(2) == [0x58, 30]
}

# Malformed input: an error, never a crash and never a large allocation

## A text length near 2^64: the sum with the position overflowed.
expect {
	r : Try(Str, _)
	r = Cbor.parse([0x7b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
	r == Err(InvalidCbor(0))
}

## A byte string length near 2^64.
expect {
	r : Try(Cbor.Bytes, _)
	r = Cbor.parse([0x5b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
	r == Err(InvalidCbor(0))
}

## An array count larger than the input: the derived parser allocated the count first.
expect {
	r : Try(List(U64), _)
	r = Cbor.parse([0x9b, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00])
	r == Err(InvalidCbor(0))
}

## A byte string length larger than the input, read as a List(U8).
expect {
	r : Try(List(U8), _)
	r = Cbor.parse([0x5b, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00])
	r == Err(InvalidCbor(0))
}

## A map count larger than the input, read as a Dict.
expect {
	r : Try(Dict(Str, U64), _)
	r = Cbor.parse([0xbb, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00])
	r == Err(InvalidCbor(0))
}

## An unknown field with a map count near 2^64: the item count overflowed.
expect {
	r : Try({ n : U64 }, _)
	r = Cbor.parse([0xa1, 0x61, 0x78, 0xbb, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
	r == Err(InvalidCbor(3))
}

## An unknown field with a text length near 2^64.
expect {
	r : Try({ n : U64 }, _)
	r = Cbor.parse([0xa1, 0x61, 0x78, 0x7b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
	r == Err(InvalidCbor(3))
}

## An unknown field with 100,000 nested arrays: the recursion overflowed the stack.
expect {
	bytes = [0xa1, 0x61, 0x78].concat(List.repeat(0x81, 100000)).append(0x00)
	r : Try({ n : Try(U64, [Missing]) }, _)
	r = Cbor.parse(bytes)
	r == Ok({ n: Err(Missing) })
}

## A byte string reads as a List(U8) only. Its bytes are not the items of another type.
expect {
	r : Try(List(U64), _)
	r = Cbor.parse([0x42, 0x01, 0x02])
	r == Err(InvalidCbor(1))
}

expect {
	r : Try(List(Bool), _)
	r = Cbor.parse([0x41, 0xf5])
	r == Err(InvalidCbor(1))
}

expect {
	r : Try(List(Try(U64, [Null])), _)
	r = Cbor.parse([0x41, 0xf6])
	r == Err(InvalidCbor(1))
}

## An unknown field with more items than bytes: the error is at the first item that cannot fit.
expect {
	r : Try({ n : U64 }, _)
	r = Cbor.parse([0xa1, 0x61, 0x78, 0x82, 0x81, 0x00])
	r == Err(InvalidCbor(4))
}

## An F32 reads an f64 that is outside the F32 range as an error, not as an infinity.
expect {
	r : Try(F32, _)
	r = Cbor.parse(Cbor.encode(1.0e300.F64))
	r == Err(InvalidCbor(0))
}

## The largest F32, an infinity and NaN still read as an F32.
expect {
	r : Try(List(F32), _)
	r = Cbor.parse(Cbor.encode([F32.highest.to_f64(), -(F32.highest.to_f64()), F64.infinity]))
	r == Ok([F32.highest, -F32.highest, F32.infinity])
}

expect {
	r : Try(F32, _)
	r = Cbor.parse(Cbor.encode(F64.nan))
	match r {
		Ok(f) => f.is_nan()
		Err(_) => Bool.False
	}
}

# Integers from floats and from text, and path_at

## [{"name": "a", "id": f64 2^53}]. The value of "id" starts at 12.
float_big : List(U8)
float_big = [0x81, 0xa2, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x61, 0x61, 0x62, 0x69, 0x64, 0xfb, 0x43, 0x40, 0, 0, 0, 0, 0, 0]

## The CBOR text of `s` (255 bytes or less).
cbor_text : Str -> List(U8)
cbor_text = |s| {
	n = s.count_utf8_bytes().to_u8_wrap()
	head_bytes = if (n < 24) [0x60 + n] else [0x78, n]
	head_bytes.concat(s.to_utf8())
}

ints : Cbor.Options
ints = { fields: Snake, int_from_text: Bool.True }

## An f64 of 2^53 or more is an error for an integer type: it can be the rounded value of many integers.
expect {
	r : Try(List({ name : Str, id : I64 }), _)
	r = Cbor.parse(float_big)
	r == Err(InvalidCbor(12))
}

## An f64 of size 2^53 - 1 or less reads as an integer.
expect {
	r : Try(I64, _)
	r = Cbor.parse([0xfb, 0x43, 0x3f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
	r == Ok(9007199254740991)
}

expect {
	r : Try(I64, _)
	r = Cbor.parse([0xfb, 0xc3, 0x3f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
	r == Ok(-9007199254740991)
}

## An f64 of -2^53 is an error for an integer type.
expect {
	r : Try(I64, _)
	r = Cbor.parse([0xfb, 0xc3, 0x40, 0, 0, 0, 0, 0, 0])
	r == Err(InvalidCbor(0))
}

## An f64 of 2^53 still reads as an F64.
expect {
	r : Try(F64, _)
	r = Cbor.parse(float_big.drop_first(12))
	r == Ok(9007199254740992.0)
}

## int_from_text: canonical decimal text in the range of the type reads as an integer.
expect {
	r : Try(I64, _)
	r = Cbor.parse_with(cbor_text("-9223372036854775808"), ints)
	r == Ok(-9223372036854775808)
}

expect {
	r : Try(I64, _)
	r = Cbor.parse_with(cbor_text("9223372036854775807"), ints)
	r == Ok(9223372036854775807)
}

expect {
	r : Try(I64, _)
	r = Cbor.parse_with(cbor_text("0"), ints)
	r == Ok(0)
}

expect {
	r : Try(U64, _)
	r = Cbor.parse_with(cbor_text("18446744073709551615"), ints)
	r == Ok(18446744073709551615)
}

## int_from_text: a value out of the range of the type is an error.
expect {
	r : Try(I64, _)
	r = Cbor.parse_with(cbor_text("9223372036854775808"), ints)
	r == Err(InvalidCbor(0))
}

expect {
	r : Try(U8, _)
	r = Cbor.parse_with(cbor_text("256"), ints)
	r == Err(InvalidCbor(0))
}

expect {
	r : Try(U64, _)
	r = Cbor.parse_with(cbor_text("-1"), ints)
	r == Err(InvalidCbor(0))
}

## int_from_text: text that is not canonical is an error.
expect
	["-0", "01", "+1", " 1", "1 ", "1.0", "1e3", "", "-", "0x10", "123456789012345678901"].all(
		|s| {
			r : Try(I64, _)
			r = Cbor.parse_with(cbor_text(s), ints)
			r == Err(InvalidCbor(0))
		},
	)

## Without int_from_text, text is an error for an integer type.
expect {
	r : Try(I64, _)
	r = Cbor.parse(cbor_text("12"))
	r == Err(InvalidCbor(0))
}

## int_from_text does not change a Str.
expect {
	r : Try(Str, _)
	r = Cbor.parse_with(cbor_text("12"), ints)
	r == Ok("12")
}

## int_from_text in a record field. A bad value is an error at its position.
expect {
	r : Try(List({ name : Str, id : I64 }), _)
	r = Cbor.parse_with([0x81, 0xa2, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x61, 0x61, 0x62, 0x69, 0x64].concat(cbor_text("123")), ints)
	r == Ok([{ name: "a", id: 123 }])
}

expect {
	r : Try(List({ name : Str, id : I64 }), _)
	r = Cbor.parse_with([0x81, 0xa2, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x61, 0x61, 0x62, 0x69, 0x64].concat(cbor_text("1.5")), ints)
	r == Err(InvalidCbor(12))
}

## int_from_text: 45 digits is an error, not an overflow of the I128 of the decoder.
expect {
	r : Try(U64, _)
	r = Cbor.parse_with(cbor_text(Str.repeat("9", 45)), ints)
	r == Err(InvalidCbor(0))
}

## fields: Camel is the same as parse_camel.
expect {
	bytes = [0xa1, 0x66, 0x75, 0x73, 0x65, 0x72, 0x49, 0x64, 0x07]
	a : Try({ user_id : U64 }, _)
	a = Cbor.parse_with(bytes, { fields: Camel, int_from_text: Bool.False })
	b : Try({ user_id : U64 }, _)
	b = Cbor.parse_camel(bytes)
	a == Ok({ user_id: 7 }) and a == b
}

## path_at names the item of an error position.
expect Cbor.path_at(float_big, 12) == Ok([Index(0), Key("id")])
expect Cbor.path_at(float_big, 7) == Ok([Index(0), Key("name")])
expect Cbor.path_at(float_big, 1) == Ok([Index(0)])
expect Cbor.path_at(float_big, 0) == Ok([])

## A position in the middle of an item, at a map key, or past the end: not found.
expect Cbor.path_at(float_big, 13) == Err(NotFound)
expect Cbor.path_at(float_big, 2) == Err(NotFound)
expect Cbor.path_at(float_big, 99) == Err(NotFound)

## The second item of an array, after a nested map, and in a tagged value.
expect Cbor.path_at([0x82, 0xa1, 0x61, 0x61, 0x81, 0x01, 0x02], 6) == Ok([Index(1)])
expect Cbor.path_at([0x82, 0xa1, 0x61, 0x61, 0x81, 0x01, 0x02], 5) == Ok([Index(0), Key("a"), Index(0)])
expect Cbor.path_at([0xc1, 0x82, 0x01, 0x02], 3) == Ok([Index(1)])

## 100,000 nested arrays: a loop, not a recursion.
expect Cbor.path_at(List.repeat(0x81, 100000).append(0x00), 100000) == Ok(List.repeat(Index(0), 100000))
