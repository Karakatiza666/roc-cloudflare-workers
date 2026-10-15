## Js.roc with a direct integer read (bench only). A JS value that crosses the bridge (API.md 5). Prototype of the byte format.
Js2 := [
	Undefined,
	Null,
	Bool(Bool),
	Num(F64),
	Int(I64),
	Text(Str),
	Bytes(List(U8)),
	Arr(List(Js2)),
	Obj(List((Str, Js2))),
	Ref(U32),
	Error(Str, Str),
].{
	is_eq : _

	encode : Js2 -> List(U8)
	encode = |v| put(List.with_capacity(64), v)

	decode : List(U8) -> Try(Js2, [Bad(U64)])
	decode = |buf| {
		(v, end) = take(buf, 0)?
		if end == buf.len() Ok(v) else Err(Bad(end))
	}
}

put : List(U8), Js2 -> List(U8)
put = |out, v| match v {
	Undefined => out.append(0)
	Null => out.append(1)
	Bool(b) => out.append(if b 3 else 2)
	Num(f) => put_u64(out.append(4), f.to_bits())
	Int(i) => put_u64(out.append(5), i.to_u64_wrap())
	Text(s) => put_bytes(out.append(6), s.to_utf8())
	Bytes(b) => put_bytes(out.append(7), b)
	Arr(items) => {
		var $o = put_u32(out.append(8), items.len())
		for item in items {
			$o = put($o, item)
		}
		$o
	}
	Obj(fields) => {
		var $o = put_u32(out.append(9), fields.len())
		for field in fields {
			(k, x) = field
			$o = put(put_bytes($o, k.to_utf8()), x)
		}
		$o
	}
	Ref(id) => put_u32(out.append(10), id.to_u64())
	Error(name, message) => put_bytes(put_bytes(out.append(11), name.to_utf8()), message.to_utf8())
}

put_u32 : List(U8), U64 -> List(U8)
put_u32 = |out, n| {
	var $o = out
	for i in 0.U8.until(4) {
		$o = $o.append(n.shr_zf_wrap(i * 8).to_u8_wrap())
	}
	$o
}

put_u64 : List(U8), U64 -> List(U8)
put_u64 = |out, n| {
	var $o = out
	for i in 0.U8.until(8) {
		$o = $o.append(n.shr_zf_wrap(i * 8).to_u8_wrap())
	}
	$o
}

put_bytes : List(U8), List(U8) -> List(U8)
put_bytes = |out, b| put_u32(out, b.len()).concat(b)

get_uint : List(U8), U64, U8 -> Try(U64, [Bad(U64)])
get_uint = |buf, at, size| {
	if at + size.to_u64() > buf.len() {
		return Err(Bad(at))
	}
	b = |i| (buf.get(at + i) ?? 0).to_u64()
	lo = b(0).bitwise_or(b(1).shl_wrap(8)).bitwise_or(b(2).shl_wrap(16)).bitwise_or(b(3).shl_wrap(24))
	if size == 4 {
		Ok(lo)
	} else {
		hi = b(4).bitwise_or(b(5).shl_wrap(8)).bitwise_or(b(6).shl_wrap(16)).bitwise_or(b(7).shl_wrap(24))
		Ok(lo.bitwise_or(hi.shl_wrap(32)))
	}
}

take_bytes : List(U8), U64 -> Try((List(U8), U64), [Bad(U64)])
take_bytes = |buf, at| {
	len = get_uint(buf, at, 4)?
	if at + 4 + len > buf.len() {
		return Err(Bad(at))
	}
	Ok((buf.sublist({ start: at + 4, len }), at + 4 + len))
}

take_text : List(U8), U64 -> Try((Str, U64), [Bad(U64)])
take_text = |buf, at| {
	(b, end) = take_bytes(buf, at)?
	match Str.from_utf8(b) {
		Ok(s) => Ok((s, end))
		Err(_) => Err(Bad(at))
	}
}

take : List(U8), U64 -> Try((Js2, U64), [Bad(U64)])
take = |buf, at| {
	tag = buf.get(at) ?? 255
	p = at + 1
	match tag {
		0 => Ok((Undefined, p))
		1 => Ok((Null, p))
		2 => Ok((Bool(Bool.False), p))
		3 => Ok((Bool(Bool.True), p))
		4 => Ok((Num(F64.from_bits(get_uint(buf, p, 8)?)), p + 8))
		5 => Ok((Int(get_uint(buf, p, 8)?.to_i64_wrap()), p + 8))
		6 => {
			(s, end) = take_text(buf, p)?
			Ok((Text(s), end))
		}
		7 => {
			(b, end) = take_bytes(buf, p)?
			Ok((Bytes(b), end))
		}
		8 => {
			n = get_uint(buf, p, 4)?
			var $at = p + 4
			var $items = List.with_capacity(n)
			for _ in 0.U64.until(n) {
				(x, end) = take(buf, $at)?
				$items = $items.append(x)
				$at = end
			}
			Ok((Arr($items), $at))
		}
		9 => {
			n = get_uint(buf, p, 4)?
			var $at = p + 4
			var $fields = List.with_capacity(n)
			for _ in 0.U64.until(n) {
				(k, kend) = take_text(buf, $at)?
				(x, end) = take(buf, kend)?
				$fields = $fields.append((k, x))
				$at = end
			}
			Ok((Obj($fields), $at))
		}
		10 => {
			id = get_uint(buf, p, 4)?
			Ok((Ref(id.to_u32_try() ?? 0), p + 4))
		}
		11 => {
			(name, nend) = take_text(buf, p)?
			(message, end) = take_text(buf, nend)?
			Ok((Error(name, message), end))
		}
		_ => Err(Bad(at))
	}
}

sample : Js2
sample = Obj([
	("results", Arr([Arr([Text("roc-lang/http"), Int(-3), Num(1.5), Null, Bool(Bool.True)])])),
	("bytes", Bytes([0, 255, 128])),
	("stream", Ref(7)),
	("meta", Obj([("changes", Int(9223372036854775807)), ("e", Error("TypeError", "x"))])),
	("u", Undefined),
])

expect Js2.decode(Js2.encode(sample)) == Ok(sample)

expect Js2.encode(Text("hi")) == [6, 2, 0, 0, 0, 104, 105]

expect Js2.decode([6, 2, 0, 0, 0, 104]) == Err(Bad(1))

expect Js2.decode([3, 0]) == Err(Bad(1))
