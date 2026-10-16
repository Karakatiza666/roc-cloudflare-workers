## CBOR (RFC 8949) as a format of the Roc codec protocol. The derived `parser_for` and
## `encoder_for` of a type read and write it, as they do for `Json` (MODULES.md MC5, API.md AQ8).
##
## Data model: the same as `Json`. A record is a map with text keys, a tag with no payload is
## text, a tag with payloads is a map of one entry, a list and a tuple are arrays. So JS sees
## the same objects as from `JSON.parse`.
##
## Profile: definite lengths only. Any argument width is read. Integers are major types 0 and 1.
## Floats are f16, f32 or f64 when read, f64 when written. `null` and `undefined` both read as null.
## A byte string reads as a `List(U8)`. A `List(U8)` writes as an array (the protocol has no bytes hook).
## `Cbor.Bytes` reads and writes a byte string (major type 2), so JS gets a `Uint8Array`.
Cbor := [Default, CamelCase].{
	State :: { bytes : List(U8), pos : U64, raw : U64 }

	a.Parseable(errs) :
		where [
			a.parser_for : Cbor -> (Cbor.State -> Try({ value : a, rest : Cbor.State }, errs)),
		]

	a.Encodable(err) :
		where [
			a.encoder_for : Cbor -> (a, List(U8) -> Try(List(U8), err)),
		]

	## Bytes that cross as a CBOR byte string, so JS gets a `Uint8Array`. A `List(U8)`
	## writes as an array of numbers, because the derived encoder has no hook for bytes.
	Bytes := List(U8).{
		is_eq : _

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

		encoder_for : encoding -> (Cbor.Bytes, state -> Try(state, err))
			where [
				encoding.encode_bytes : List(U8), state -> Try(state, err),
			]
		encoder_for = |_| {
			Encoding : encoding

			|Cbor.Bytes.(bytes), state| Encoding.encode_bytes(bytes, state)
		}

		to_list : Cbor.Bytes -> List(U8)
		to_list = |Cbor.Bytes.(bytes)| bytes
	}

	parse : List(U8) -> Try(a, [InvalidCbor(U64), ..errs]) where [a.Parseable([InvalidCbor(U64), ..errs])]
	parse = |bytes| {
		Shape : a
		parse_shape = Shape.parser_for(Cbor.Default)
		parsed = parse_shape(Cbor.State.{ bytes, pos: 0, raw: 0 })?
		if parsed.rest.pos == bytes.len() Ok(parsed.value) else Err(InvalidCbor(parsed.rest.pos))
	}

	## Record fields in camelCase, for a JS peer.
	parse_camel : List(U8) -> Try(a, [InvalidCbor(U64), ..errs]) where [a.Parseable([InvalidCbor(U64), ..errs])]
	parse_camel = |bytes| {
		Shape : a
		parse_shape = Shape.parser_for(Cbor.CamelCase)
		parsed = parse_shape(Cbor.State.{ bytes, pos: 0, raw: 0 })?
		if parsed.rest.pos == bytes.len() Ok(parsed.value) else Err(InvalidCbor(parsed.rest.pos))
	}

	encode : a -> List(U8) where [a.Encodable([])]
	encode = |value| {
		Shape : a
		encode_shape = Shape.encoder_for(Cbor.Default)
		match encode_shape(value, List.with_capacity(256)) {
			Ok(out) => out
		}
	}

	rename_field : Cbor, Str -> Str
	rename_field = |encoding, name|
		match encoding {
			Default => name
			CamelCase => Json.snake_to_camel(name)
		}

	invalid_value : Cbor, Cbor.State -> [InvalidCbor(U64)]
	invalid_value = |_, state| InvalidCbor(state.pos)

	# Scalars

	parse_str : Cbor, Cbor.State -> Try({ value : Str, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_str = |_, state| text(state)

	## A byte string (major type 2) only. `Cbor.Bytes` calls it.
	parse_bytes : Cbor, Cbor.State -> Try({ value : List(U8), rest : Cbor.State }, [InvalidCbor(U64)])
	parse_bytes = |_, state| {
		h = head(state)?
		if h.major != 2 or h.next + h.arg > state.bytes.len() {
			return Err(InvalidCbor(state.pos))
		}
		Ok({ value: state.bytes.sublist({ start: h.next, len: h.arg }), rest: at(state, h.next + h.arg) })
	}

	parse_bool : Cbor, Cbor.State -> Try({ value : Bool, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_bool = |_, state|
		match state.bytes.get(state.pos) {
			Ok(0xf4) => Ok({ value: Bool.False, rest: at(state, state.pos + 1) })
			Ok(0xf5) => Ok({ value: Bool.True, rest: at(state, state.pos + 1) })
			_ => Err(InvalidCbor(state.pos))
		}

	parse_null : Cbor, Cbor.State -> Try(Cbor.State, [InvalidCbor(U64)])
	parse_null = |_, state|
		match state.bytes.get(state.pos) {
			Ok(0xf6) | Ok(0xf7) => Ok(at(state, state.pos + 1))
			_ => Err(InvalidCbor(state.pos))
		}

	parse_u8 : Cbor, Cbor.State -> Try({ value : U8, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_u8 = |_, state|
		if state.raw > 0 {
			# An item of a byte string read as a List(U8).
			b = state.bytes.get(state.pos) ? |_| InvalidCbor(state.pos)
			Ok({ value: b, rest: Cbor.State.{ bytes: state.bytes, pos: state.pos + 1, raw: state.raw - 1 } })
		} else {
			n = int(state)?
			v = n.value.to_u8_try() ? |_| InvalidCbor(state.pos)
			Ok({ value: v, rest: n.rest })
		}

	parse_u16 : Cbor, Cbor.State -> Try({ value : U16, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_u16 = |_, state| {
		n = int(state)?
		Ok({ value: n.value.to_u16_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	parse_u32 : Cbor, Cbor.State -> Try({ value : U32, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_u32 = |_, state| {
		n = int(state)?
		Ok({ value: n.value.to_u32_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	parse_u64 : Cbor, Cbor.State -> Try({ value : U64, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_u64 = |_, state| {
		n = int(state)?
		Ok({ value: n.value.to_u64_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	parse_i8 : Cbor, Cbor.State -> Try({ value : I8, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_i8 = |_, state| {
		n = int(state)?
		Ok({ value: n.value.to_i8_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	parse_i16 : Cbor, Cbor.State -> Try({ value : I16, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_i16 = |_, state| {
		n = int(state)?
		Ok({ value: n.value.to_i16_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	parse_i32 : Cbor, Cbor.State -> Try({ value : I32, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_i32 = |_, state| {
		n = int(state)?
		Ok({ value: n.value.to_i32_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	parse_i64 : Cbor, Cbor.State -> Try({ value : I64, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_i64 = |_, state| {
		n = int(state)?
		Ok({ value: n.value.to_i64_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	parse_f64 : Cbor, Cbor.State -> Try({ value : F64, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_f64 = |_, state| float(state)

	parse_f32 : Cbor, Cbor.State -> Try({ value : F32, rest : Cbor.State }, [InvalidCbor(U64)])
	parse_f32 = |_, state| {
		f = float(state)?
		Ok({ value: f.value.to_f32_wrap(), rest: f.rest })
	}

	# Containers

	parse_list_start : Cbor, Cbor.State -> Try([Counted({ len : U64, rest : Cbor.State }), Uncounted(Cbor.State)], [InvalidCbor(U64)])
	parse_list_start = |_, state| {
		h = head(state)?
		match h.major {
			4 => Ok(Counted({ len: h.arg, rest: at(state, h.next) }))
			2 => Ok(Counted({ len: h.arg, rest: Cbor.State.{ bytes: state.bytes, pos: h.next, raw: h.arg } }))
			_ => Err(InvalidCbor(state.pos))
		}
	}

	## Not called: each list is counted.
	parse_list_next : Cbor, Cbor.State -> Try([Item(Cbor.State), Done(Cbor.State)], [InvalidCbor(U64)])
	parse_list_next = |_, state| Err(InvalidCbor(state.pos))

	parse_list_after_item : Cbor, Cbor.State -> Try([Continue(Cbor.State), Done(Cbor.State)], [InvalidCbor(U64)])
	parse_list_after_item = |_, state| Err(InvalidCbor(state.pos))

	parse_tuple_start : Cbor, Cbor.State, U64 -> Try(Cbor.State, [InvalidCbor(U64)])
	parse_tuple_start = |_, state, len| {
		h = head(state)?
		if h.major == 4 and h.arg == len Ok(at(state, h.next)) else Err(InvalidCbor(state.pos))
	}

	parse_tuple_next : Cbor, Cbor.State, U64, U64 -> Try(Cbor.State, [InvalidCbor(U64)])
	parse_tuple_next = |_, state, _, _| Ok(state)

	parse_tuple_end : Cbor, Cbor.State, U64 -> Try(Cbor.State, [InvalidCbor(U64)])
	parse_tuple_end = |_, state, _| Ok(state)

	parse_record_start : Cbor, Cbor.State -> Try([Counted({ len : U64, rest : Cbor.State }), Uncounted(Cbor.State)], [InvalidCbor(U64)])
	parse_record_start = |_, state| {
		h = head(state)?
		if h.major == 5 Ok(Counted({ len: h.arg, rest: at(state, h.next) })) else Err(InvalidCbor(state.pos))
	}

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
	parse_record_field = |_, _, state| {
		key = text(state)?
		Ok(TryField({ name: key.value, rest: key.rest }))
	}

	## Not called: each map is counted.
	parse_record_after_field : Cbor, Cbor.State -> Try([Continue(Cbor.State), Done(Cbor.State)], [InvalidCbor(U64)])
	parse_record_after_field = |_, state| Err(InvalidCbor(state.pos))

	skip_record_field : Cbor, Cbor.State -> Try(Cbor.State, [InvalidCbor(U64)])
	skip_record_field = |_, state| skip(state)

	parse_dict_start : Cbor, Cbor.State -> Try([Counted({ len : U64, rest : Cbor.State }), Uncounted(Cbor.State)], [InvalidCbor(U64)])
	parse_dict_start = |encoding, state| parse_record_start(encoding, state)

	parse_dict_next : Cbor, Cbor.State -> Try([Entry(Cbor.State), Done(Cbor.State)], [InvalidCbor(U64)])
	parse_dict_next = |_, state| Err(InvalidCbor(state.pos))

	parse_dict_after_key : Cbor, Cbor.State -> Try(Cbor.State, [InvalidCbor(U64)])
	parse_dict_after_key = |_, state| Ok(state)

	parse_dict_after_entry : Cbor, Cbor.State -> Try([Continue(Cbor.State), Done(Cbor.State)], [InvalidCbor(U64)])
	parse_dict_after_entry = |_, state| Err(InvalidCbor(state.pos))

	parse_key_start : Cbor, Cbor.State -> Try(Cbor.State, [InvalidCbor(U64)])
	parse_key_start = |_, state| Ok(state)

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
						start_payloads: |s, count| if count == 0 Ok(s) else Err(InvalidCbor(s.pos)),
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
								if t.major == 4 and t.arg == count Ok(at(s, t.next)) else Err(InvalidCbor(s.pos))
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

	encode_str : Str, List(U8) -> Try(List(U8), [])
	encode_str = |value, out| Ok(put_text(out, value))

	## A byte string (major type 2). `Cbor.Bytes` calls it.
	encode_bytes : List(U8), List(U8) -> Try(List(U8), [])
	encode_bytes = |value, out| Ok(put_head(out, 2, value.len()).concat(value))

	encode_bool : Bool, List(U8) -> Try(List(U8), [])
	encode_bool = |value, out| Ok(out.append(if value 0xf5 else 0xf4))

	encode_null : List(U8) -> Try(List(U8), [])
	encode_null = |out| Ok(out.append(0xf6))

	encode_u8 : U8, List(U8) -> Try(List(U8), [])
	encode_u8 = |value, out| Ok(put_head(out, 0, value.to_u64()))

	encode_u16 : U16, List(U8) -> Try(List(U8), [])
	encode_u16 = |value, out| Ok(put_head(out, 0, value.to_u64()))

	encode_u32 : U32, List(U8) -> Try(List(U8), [])
	encode_u32 = |value, out| Ok(put_head(out, 0, value.to_u64()))

	encode_u64 : U64, List(U8) -> Try(List(U8), [])
	encode_u64 = |value, out| Ok(put_head(out, 0, value))

	encode_i8 : I8, List(U8) -> Try(List(U8), [])
	encode_i8 = |value, out| Ok(put_int(out, value.to_i64()))

	encode_i16 : I16, List(U8) -> Try(List(U8), [])
	encode_i16 = |value, out| Ok(put_int(out, value.to_i64()))

	encode_i32 : I32, List(U8) -> Try(List(U8), [])
	encode_i32 = |value, out| Ok(put_int(out, value.to_i64()))

	encode_i64 : I64, List(U8) -> Try(List(U8), [])
	encode_i64 = |value, out| Ok(put_int(out, value))

	encode_f64 : F64, List(U8) -> Try(List(U8), [])
	encode_f64 = |value, out| Ok(put_be(out.append(0xfb), value.to_bits(), 8))

	encode_f32 : F32, List(U8) -> Try(List(U8), [])
	encode_f32 = |value, out| Ok(put_be(out.append(0xfa), value.to_bits().to_u64(), 4))

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

	encode_list : List(U8), U64, ({ out : List(U8), n : U64 }, ({ out : List(U8), n : U64 }, (List(U8) -> Try(List(U8), err)) -> Try({ out : List(U8), n : U64 }, err)) -> Try({ out : List(U8), n : U64 }, err)) -> Try(List(U8), err)
	encode_list = |out, count, write_items| {
		start = out.len()
		done = write_items(
			{ out: put_head_wide(out, 4, count), n: 0 },
			|c, write_value| Ok({ out: write_value(c.out)?, n: c.n + 1 }),
		)?
		Ok(patch_count(done.out, start, done.n))
	}

	encode_tuple : List(U8), U64, ({ out : List(U8), n : U64 }, ({ out : List(U8), n : U64 }, (List(U8) -> Try(List(U8), err)) -> Try({ out : List(U8), n : U64 }, err)) -> Try({ out : List(U8), n : U64 }, err)) -> Try(List(U8), err)
	encode_tuple = |out, count, write_items| Cbor.encode_list(out, count, write_items)

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

at : Cbor.State, U64 -> Cbor.State
at = |state, pos| Cbor.State.{ bytes: state.bytes, pos, raw: 0 }

## The initial byte and its argument (RFC 8949 3). Indefinite lengths and the reserved
## values 28 to 30 are errors in this profile.
head : Cbor.State -> Try({ major : U8, arg : U64, next : U64 }, [InvalidCbor(U64)])
head = |state| {
	p = state.pos
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
	for i in 0.U64.until(size) {
		$n = $n.shl_wrap(8).bitwise_or((bytes.get(start + i) ?? 0).to_u64())
	}
	$n
}

text : Cbor.State -> Try({ value : Str, rest : Cbor.State }, [InvalidCbor(U64)])
text = |state| {
	h = head(state)?
	if h.major != 3 or h.next + h.arg > state.bytes.len() {
		return Err(InvalidCbor(state.pos))
	}
	value = Str.from_utf8(state.bytes.sublist({ start: h.next, len: h.arg })) ? |_| InvalidCbor(state.pos)
	Ok({ value, rest: at(state, h.next + h.arg) })
}

## An integer of major type 0 or 1, as I128 so that both u64 and -2^64 fit. A float that is
## an exact integer is also read: JS writes 2^53 and more as a float when it is a Number.
int : Cbor.State -> Try({ value : I128, rest : Cbor.State }, [InvalidCbor(U64)])
int = |state| {
	h = head(state)?
	match h.major {
		0 => Ok({ value: h.arg.to_i128(), rest: at(state, h.next) })
		1 => Ok({ value: -1 - h.arg.to_i128(), rest: at(state, h.next) })
		7 => {
			f = float(state)?
			i = f.value.to_i128_try() ? |_| InvalidCbor(state.pos)
			if i.to_f64() == f.value Ok({ value: i, rest: f.rest }) else Err(InvalidCbor(state.pos))
		}
		_ => Err(InvalidCbor(state.pos))
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
			mant * 0.000000059604644775390625    # 2^-24
		} else if exp != 31 {
			(mant + 1024.0) * pow2(exp.to_i64_wrap() - 25)
		} else if mant == 0.0 {
			F64.infinity
		} else {
			F64.nan
		}
	if h.bitwise_and(0x8000) != 0 -value else value
}

pow2 : I64 -> F64
pow2 = |e| {
	var $v = 1.0.F64
	if e >= 0 {
		for _ in 0.I64.until(e) {
			$v = $v * 2.0
		}
	} else {
		for _ in 0.I64.until(-e) {
			$v = $v / 2.0
		}
	}
	$v
}

## Skip one whole item: an unknown record field.
skip : Cbor.State -> Try(Cbor.State, [InvalidCbor(U64)])
skip = |state| {
	h = head(state)?
	match h.major {
		0 | 1 | 7 => Ok(at(state, h.next))
		2 | 3 => if h.next + h.arg > state.bytes.len() Err(InvalidCbor(state.pos)) else Ok(at(state, h.next + h.arg))
		4 | 5 => {
			items = if h.major == 5 h.arg * 2 else h.arg
			var $s = at(state, h.next)
			for _ in 0.U64.until(items) {
				$s = skip($s)?
			}
			Ok($s)
		}
		_ => {
			# 6: a tag, then one item
			skip(at(state, h.next))
		}
	}
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
	for i in 0.U64.until(size) {
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
	for i in 0.U64.until(size) {
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
	xs = 0.U64.until(300).collect()
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
	b = 0.U8.until(30).collect()
	Cbor.encode(Cbor.Bytes.(b)).take_first(2) == [0x58, 30]
}
