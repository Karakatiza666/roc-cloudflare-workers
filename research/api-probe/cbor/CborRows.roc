## Variant of Cbor.roc for row sets (API.md AQ9): `parse_rows` reads `[[column names], row, row, ...]`,
## where each row is an array of values in column order, into a list of records. The names are read
## once, so a row has no keys on the wire. The rest is Cbor.roc with the type renamed.
##
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
CborRows := [Default, CamelCase].{
	State :: { bytes : List(U8), pos : U64, raw : U64, keys : List(Str), key : U64 }

	a.Parseable(errs) :
		where [
			a.parser_for : CborRows -> (CborRows.State -> Try({ value : a, rest : CborRows.State }, errs)),
		]

	a.Encodable(err) :
		where [
			a.encoder_for : CborRows -> (a, List(U8) -> Try(List(U8), err)),
		]

	parse : List(U8) -> Try(a, [InvalidCbor(U64), ..errs]) where [a.Parseable([InvalidCbor(U64), ..errs])]
	parse = |bytes| {
		Shape : a
		parse_shape = Shape.parser_for(CborRows.Default)
		parsed = parse_shape(CborRows.State.{ bytes, pos: 0, raw: 0, keys: [], key: no_key })?
		if parsed.rest.pos == bytes.len() Ok(parsed.value) else Err(InvalidCbor(parsed.rest.pos))
	}

	## Record fields in camelCase, for a JS peer.
	parse_camel : List(U8) -> Try(a, [InvalidCbor(U64), ..errs]) where [a.Parseable([InvalidCbor(U64), ..errs])]
	parse_camel = |bytes| {
		Shape : a
		parse_shape = Shape.parser_for(CborRows.CamelCase)
		parsed = parse_shape(CborRows.State.{ bytes, pos: 0, raw: 0, keys: [], key: no_key })?
		if parsed.rest.pos == bytes.len() Ok(parsed.value) else Err(InvalidCbor(parsed.rest.pos))
	}

	encode : a -> List(U8) where [a.Encodable([])]
	encode = |value| {
		Shape : a
		encode_shape = Shape.encoder_for(CborRows.Default)
		match encode_shape(value, List.with_capacity(256)) {
			Ok(out) => out
		}
	}

	rename_field : CborRows, Str -> Str
	rename_field = |encoding, name|
		match encoding {
			Default => name
			CamelCase => Json.snake_to_camel(name)
		}

	invalid_value : CborRows, CborRows.State -> [InvalidCbor(U64)]
	invalid_value = |_, state| InvalidCbor(state.pos)

	# Scalars

	parse_str : CborRows, CborRows.State -> Try({ value : Str, rest : CborRows.State }, [InvalidCbor(U64)])
	parse_str = |_, state| text(state)

	parse_bool : CborRows, CborRows.State -> Try({ value : Bool, rest : CborRows.State }, [InvalidCbor(U64)])
	parse_bool = |_, state|
		match state.bytes.get(state.pos) {
			Ok(0xf4) => Ok({ value: Bool.False, rest: at(state, state.pos + 1) })
			Ok(0xf5) => Ok({ value: Bool.True, rest: at(state, state.pos + 1) })
			_ => Err(InvalidCbor(state.pos))
		}

	parse_null : CborRows, CborRows.State -> Try(CborRows.State, [InvalidCbor(U64)])
	parse_null = |_, state|
		match state.bytes.get(state.pos) {
			Ok(0xf6) | Ok(0xf7) => Ok(at(state, state.pos + 1))
			_ => Err(InvalidCbor(state.pos))
		}

	parse_u8 : CborRows, CborRows.State -> Try({ value : U8, rest : CborRows.State }, [InvalidCbor(U64)])
	parse_u8 = |_, state|
		if state.raw > 0 {
			# An item of a byte string read as a List(U8).
			b = state.bytes.get(state.pos) ? |_| InvalidCbor(state.pos)
			Ok({ value: b, rest: CborRows.State.{ bytes: state.bytes, pos: state.pos + 1, raw: state.raw - 1, keys: state.keys, key: state.key } })
		} else {
			n = int(state)?
			v = n.value.to_u8_try() ? |_| InvalidCbor(state.pos)
			Ok({ value: v, rest: n.rest })
		}

	parse_u16 : CborRows, CborRows.State -> Try({ value : U16, rest : CborRows.State }, [InvalidCbor(U64)])
	parse_u16 = |_, state| {
		n = int(state)?
		Ok({ value: n.value.to_u16_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	parse_u32 : CborRows, CborRows.State -> Try({ value : U32, rest : CborRows.State }, [InvalidCbor(U64)])
	parse_u32 = |_, state| {
		n = int(state)?
		Ok({ value: n.value.to_u32_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	parse_u64 : CborRows, CborRows.State -> Try({ value : U64, rest : CborRows.State }, [InvalidCbor(U64)])
	parse_u64 = |_, state| {
		n = int(state)?
		Ok({ value: n.value.to_u64_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	parse_i8 : CborRows, CborRows.State -> Try({ value : I8, rest : CborRows.State }, [InvalidCbor(U64)])
	parse_i8 = |_, state| {
		n = int(state)?
		Ok({ value: n.value.to_i8_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	parse_i16 : CborRows, CborRows.State -> Try({ value : I16, rest : CborRows.State }, [InvalidCbor(U64)])
	parse_i16 = |_, state| {
		n = int(state)?
		Ok({ value: n.value.to_i16_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	parse_i32 : CborRows, CborRows.State -> Try({ value : I32, rest : CborRows.State }, [InvalidCbor(U64)])
	parse_i32 = |_, state| {
		n = int(state)?
		Ok({ value: n.value.to_i32_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	parse_i64 : CborRows, CborRows.State -> Try({ value : I64, rest : CborRows.State }, [InvalidCbor(U64)])
	parse_i64 = |_, state| {
		n = int(state)?
		Ok({ value: n.value.to_i64_try() ? |_| InvalidCbor(state.pos), rest: n.rest })
	}

	parse_f64 : CborRows, CborRows.State -> Try({ value : F64, rest : CborRows.State }, [InvalidCbor(U64)])
	parse_f64 = |_, state| float(state)

	parse_f32 : CborRows, CborRows.State -> Try({ value : F32, rest : CborRows.State }, [InvalidCbor(U64)])
	parse_f32 = |_, state| {
		f = float(state)?
		Ok({ value: f.value.to_f32_wrap(), rest: f.rest })
	}

	# Containers

	parse_list_start : CborRows, CborRows.State -> Try([Counted({ len : U64, rest : CborRows.State }), Uncounted(CborRows.State)], [InvalidCbor(U64)])
	parse_list_start = |_, state| {
		h = head(state)?
		match h.major {
			4 => Ok(Counted({ len: h.arg, rest: at(state, h.next) }))
			2 => Ok(Counted({ len: h.arg, rest: CborRows.State.{ bytes: state.bytes, pos: h.next, raw: h.arg, keys: [], key: no_key } }))
			_ => Err(InvalidCbor(state.pos))
		}
	}

	## Not called: each list is counted.
	parse_list_next : CborRows, CborRows.State -> Try([Item(CborRows.State), Done(CborRows.State)], [InvalidCbor(U64)])
	parse_list_next = |_, state| Err(InvalidCbor(state.pos))

	parse_list_after_item : CborRows, CborRows.State -> Try([Continue(CborRows.State), Done(CborRows.State)], [InvalidCbor(U64)])
	parse_list_after_item = |_, state| Err(InvalidCbor(state.pos))

	parse_tuple_start : CborRows, CborRows.State, U64 -> Try(CborRows.State, [InvalidCbor(U64)])
	parse_tuple_start = |_, state, len| {
		h = head(state)?
		if h.major == 4 and h.arg == len Ok(at(state, h.next)) else Err(InvalidCbor(state.pos))
	}

	parse_tuple_next : CborRows, CborRows.State, U64, U64 -> Try(CborRows.State, [InvalidCbor(U64)])
	parse_tuple_next = |_, state, _, _| Ok(state)

	parse_tuple_end : CborRows, CborRows.State, U64 -> Try(CborRows.State, [InvalidCbor(U64)])
	parse_tuple_end = |_, state, _| Ok(state)

	parse_record_start : CborRows, CborRows.State -> Try([Counted({ len : U64, rest : CborRows.State }), Uncounted(CborRows.State)], [InvalidCbor(U64)])
	parse_record_start = |_, state| {
		h = head(state)?
		if h.major == 5 {
			Ok(Counted({ len: h.arg, rest: CborRows.State.{ bytes: state.bytes, pos: h.next, raw: 0, keys: [], key: no_key } }))
		} else if h.major == 4 and h.arg == state.keys.len() and h.arg > 0 {
			Ok(Counted({ len: h.arg, rest: CborRows.State.{ bytes: state.bytes, pos: h.next, raw: 0, keys: state.keys, key: 0 } }))
		} else {
			Err(InvalidCbor(state.pos))
		}
	}

	parse_record_field : CborRows,
	Encoding.FieldName.FieldNames(_shape),
	CborRows.State -> Try(
		[
			Field({ field : Encoding.FieldName(_shape), rest : CborRows.State }),
			TryField({ name : Str, rest : CborRows.State }),
			TryFieldCaseless({ name : Str, rest : CborRows.State }),
			Continue(CborRows.State),
			Done(CborRows.State),
		],
		[InvalidCbor(U64)],
	)
	parse_record_field = |_, _, state|
		if state.key != no_key {
			name = state.keys.get(state.key) ? |_| InvalidCbor(state.pos)
			Ok(TryField({ name, rest: CborRows.State.{ bytes: state.bytes, pos: state.pos, raw: 0, keys: state.keys, key: state.key + 1 } }))
		} else {
			key = text(state)?
			Ok(TryField({ name: key.value, rest: key.rest }))
		}

	## `[[column names], row, ...]` into a list of records. A row is an array of values in column
	## order. A value in a row must be a scalar: the key position is kept in the state.
	parse_rows : List(U8) -> Try(List(a), [InvalidCbor(U64), ..errs]) where [a.Parseable([InvalidCbor(U64), ..errs])]
	parse_rows = |bytes| {
		Item : a
		parse_item = Item.parser_for(CborRows.Default)
		start = CborRows.State.{ bytes, pos: 0, raw: 0, keys: [], key: no_key }
		outer = head(start)?
		if outer.major != 4 or outer.arg == 0 {
			return Err(InvalidCbor(0))
		}
		names_head = head(at(start, outer.next))?
		if names_head.major != 4 {
			return Err(InvalidCbor(outer.next))
		}
		var $s = at(start, names_head.next)
		var $keys = List.with_capacity(names_head.arg)
		for _ in 0.U64.until(names_head.arg) {
			k = text($s)?
			$keys = $keys.append(k.value)
			$s = k.rest
		}
		var $rows = List.with_capacity(outer.arg - 1)
		var $row_state = CborRows.State.{ bytes, pos: $s.pos, raw: 0, keys: $keys, key: no_key }
		for _ in 1.U64.until(outer.arg) {
			parsed = parse_item($row_state)?
			$rows = $rows.append(parsed.value)
			$row_state = CborRows.State.{ bytes, pos: parsed.rest.pos, raw: 0, keys: $keys, key: no_key }
		}
		if $row_state.pos == bytes.len() Ok($rows) else Err(InvalidCbor($row_state.pos))
	}

	## Not called: each map is counted.
	parse_record_after_field : CborRows, CborRows.State -> Try([Continue(CborRows.State), Done(CborRows.State)], [InvalidCbor(U64)])
	parse_record_after_field = |_, state| Err(InvalidCbor(state.pos))

	skip_record_field : CborRows, CborRows.State -> Try(CborRows.State, [InvalidCbor(U64)])
	skip_record_field = |_, state| skip(state)

	parse_dict_start : CborRows, CborRows.State -> Try([Counted({ len : U64, rest : CborRows.State }), Uncounted(CborRows.State)], [InvalidCbor(U64)])
	parse_dict_start = |encoding, state| parse_record_start(encoding, state)

	parse_dict_next : CborRows, CborRows.State -> Try([Entry(CborRows.State), Done(CborRows.State)], [InvalidCbor(U64)])
	parse_dict_next = |_, state| Err(InvalidCbor(state.pos))

	parse_dict_after_key : CborRows, CborRows.State -> Try(CborRows.State, [InvalidCbor(U64)])
	parse_dict_after_key = |_, state| Ok(state)

	parse_dict_after_entry : CborRows, CborRows.State -> Try([Continue(CborRows.State), Done(CborRows.State)], [InvalidCbor(U64)])
	parse_dict_after_entry = |_, state| Err(InvalidCbor(state.pos))

	parse_key_start : CborRows, CborRows.State -> Try(CborRows.State, [InvalidCbor(U64)])
	parse_key_start = |_, state| Ok(state)

	parse_key_str : CborRows, CborRows.State -> Try({ value : Str, rest : CborRows.State }, [InvalidCbor(U64)])
	parse_key_str = |_, state| text(state)

	## Text: a tag with no payload. A map of one entry: the tag, then its payload, or an
	## array of its payloads when it has more than one. The same shapes as `Json`.
	parse_tag_union : CborRows, Encoding.ParseTagUnionSpec(a), CborRows.State -> Try({ value : a, rest : CborRows.State }, [InvalidCbor(U64)])
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
	encode_str = |value, out| {
		b = value.to_utf8()
		Ok(put_head(out, 3, b.len()).concat(b))
	}

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
				with_key = put_head(c.out, 3, name.count_utf8_bytes()).concat(name.to_utf8())
				Ok({ out: write_value(with_key)?, n: c.n + 1 })
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
	encode_tuple = |out, count, write_items| CborRows.encode_list(out, count, write_items)

	encode_tag : List(U8), Str, U64, ({ out : List(U8), n : U64 }, ({ out : List(U8), n : U64 }, (List(U8) -> Try(List(U8), err)) -> Try({ out : List(U8), n : U64 }, err)) -> Try({ out : List(U8), n : U64 }, err)) -> Try(List(U8), err)
	encode_tag = |out, tag, count, write_payloads|
		if count == 0 {
			Ok(put_head(out, 3, tag.count_utf8_bytes()).concat(tag.to_utf8()))
		} else {
			keyed = put_head(put_head(out, 5, 1), 3, tag.count_utf8_bytes()).concat(tag.to_utf8())
			if count == 1 {
				done = write_payloads({ out: keyed, n: 0 }, |c, write_value| Ok({ out: write_value(c.out)?, n: c.n + 1 }))?
				Ok(done.out)
			} else {
				CborRows.encode_list(keyed, count, write_payloads)
			}
		}
}

no_key : U64
no_key = U64.highest

## Keeps the key position, so that the value of a row field leaves it for the next field.
at : CborRows.State, U64 -> CborRows.State
at = |state, pos| CborRows.State.{ bytes: state.bytes, pos, raw: 0, keys: state.keys, key: state.key }

## The initial byte and its argument (RFC 8949 3). Indefinite lengths and the reserved
## values 28 to 30 are errors in this profile.
head : CborRows.State -> Try({ major : U8, arg : U64, next : U64 }, [InvalidCbor(U64)])
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

text : CborRows.State -> Try({ value : Str, rest : CborRows.State }, [InvalidCbor(U64)])
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
int : CborRows.State -> Try({ value : I128, rest : CborRows.State }, [InvalidCbor(U64)])
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

float : CborRows.State -> Try({ value : F64, rest : CborRows.State }, [InvalidCbor(U64)])
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
skip : CborRows.State -> Try(CborRows.State, [InvalidCbor(U64)])
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

# Row sets

expect {
	# [["name", "size"], ["a", 1], ["b", 2]]
	bytes = [0x83, 0x82, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x64, 0x73, 0x69, 0x7a, 0x65, 0x82, 0x61, 0x61, 0x01, 0x82, 0x61, 0x62, 0x02]
	r : Try(List({ name : Str, size : U64 }), _)
	r = CborRows.parse_rows(bytes)
	r == Ok([{ name: "a", size: 1 }, { name: "b", size: 2 }])
}

## A column with no field is skipped, and the next field still gets its name.
expect {
	# [["x", "name"], [7, "a"]]
	bytes = [0x82, 0x82, 0x61, 0x78, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x82, 0x07, 0x61, 0x61]
	r : Try(List({ name : Str }), _)
	r = CborRows.parse_rows(bytes)
	r == Ok([{ name: "a" }])
}

expect {
	# [["name"], ["a", 1]]: a row with more values than columns
	bytes = [0x82, 0x81, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x82, 0x61, 0x61, 0x01]
	r : Try(List({ name : Str }), _)
	r = CborRows.parse_rows(bytes)
	r.is_err()
}
