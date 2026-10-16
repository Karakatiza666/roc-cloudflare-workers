# API.md HD4: the decoder of the CBOR profile in Roc, a test oracle for the Zig decoder of host/cbor.zig.
# Written from the profile of API.md 5, apart from the Zig code. The prototype of the first byte format
# stays in research/api-probe/Js.roc.
#
# bench/hd4-test.mjs writes the two input files and runs this script:
#   corpus.bin  for each input: [len u32 LE][bytes]
#   zig.bin     for each input: [ok u8][len u32 LE][bytes]: the Zig decode, then the Zig encode (ok 0: an error)
# For each input, the oracle decodes and encodes again, and compares with the Zig result. Both must give
# a value with the same bytes, or both an error. The last line is "PASS ..." or "FAIL ...".
import "corpus.bin" as corpus : List(U8)
import "zig.bin" as zig : List(U8)

Js := [
	Undefined,
	Null,
	Bool(Bool),
	Num(F64),
	Int(I64),
	Text(Str),
	Bytes(List(U8)),
	Arr(List(Js)),
	Obj(List((Str, Js))),
	Ref(U32),
	Error(Str, Str),
	Packed(List(U8)),
]

max_depth = 64

# ---- decode

Head : { major : U8, info : U8, arg : U64, next : U64 }

be : List(U8), U64, U64 -> U64
be = |b, start, size| {
	var $x = 0
	for k in 0.U64.until(size) {
		$x = $x * 256 + (b.get(start + k) ?? 0).to_u64()
	}
	$x
}

# The head of a data item at `i`: major type, additional information and argument (any width).
head : List(U8), U64 -> Try(Head, [Bad(U64)])
head = |b, i| {
	ib = b.get(i) ? |_| Bad(i)
	major = ib // 32
	info = ib % 32
	if info < 24 {
		Ok({ major, info, arg: info.to_u64(), next: i + 1 })
	} else if info <= 27 {
		size = match info {
			24 => 1
			25 => 2
			26 => 4
			_ => 8
		}
		if i + 1 + size > b.len() Err(Bad(i)) else Ok({ major, info, arg: be(b, i + 1, size), next: i + 1 + size })
	} else {
		# 28 to 30: reserved. 31: an indefinite length or a break.
		Err(Bad(i))
	}
}

# `n` bytes at `i`, or an error when the input is shorter.
take : List(U8), U64, U64 -> Try(List(U8), [Bad(U64)])
take = |b, i, n| if n > b.len() or i > b.len() - n Err(Bad(i)) else Ok(b.sublist({ start: i, len: n }))

text_at : List(U8), U64 -> Try({ value : Str, next : U64 }, [Bad(U64)])
text_at = |b, i| {
	h = head(b, i)?
	if h.major != 3 return Err(Bad(i))
	raw = take(b, h.next, h.arg)?
	s = Str.from_utf8(raw) ? |_| Bad(i)
	Ok({ value: s, next: h.next + h.arg })
}

f64_bits : Bool, U64, U64 -> F64
f64_bits = |neg, exp, mant| F64.from_bits((if neg 9223372036854775808 else 0) + exp * 4503599627370496 + mant)

# An f16 to an f64, from the bits (exact).
half : U64 -> F64
half = |h| {
	neg = h >= 32768
	exp = (h // 1024) % 32
	mant = h % 1024
	if exp == 0 {
		# Subnormal: mant * 2^-24.
		v = mant.to_f64() * f64_bits(Bool.False, 999, 0)
		if neg -v else v
	} else if exp == 31 {
		if mant == 0 f64_bits(neg, 2047, 0) else F64.nan
	} else {
		f64_bits(neg, exp + 1008, mant * 4398046511104)
	}
}

value_at : List(U8), U64, U64 -> Try({ value : Js, next : U64 }, [Bad(U64)])
value_at = |b, i, level| {
	h = head(b, i)?
	match h.major {
		0 => {
			n = h.arg.to_i64_try() ? |_| Bad(i)
			Ok({ value: Js.Int(n), next: h.next })
		}
		1 => {
			n = h.arg.to_i64_try() ? |_| Bad(i)
			Ok({ value: Js.Int(-1 - n), next: h.next })
		}
		2 => {
			raw = take(b, h.next, h.arg)?
			Ok({ value: Js.Bytes(raw), next: h.next + h.arg })
		}
		3 => {
			t = text_at(b, i)?
			Ok({ value: Js.Text(t.value), next: t.next })
		}
		4 => {
			if level >= max_depth return Err(Bad(i))
			# Each item has 1 byte or more: a longer count is a bad length.
			if h.arg > b.len() return Err(Bad(i))
			var $at = h.next
			var $items = List.with_capacity(h.arg)
			for _ in 0.U64.until(h.arg) {
				item = value_at(b, $at, level + 1)?
				$items = $items.append(item.value)
				$at = item.next
			}
			Ok({ value: Js.Arr($items), next: $at })
		}
		5 => {
			if level >= max_depth return Err(Bad(i))
			if h.arg > b.len() return Err(Bad(i))
			var $at = h.next
			var $fields = List.with_capacity(h.arg)
			for _ in 0.U64.until(h.arg) {
				key = text_at(b, $at)?
				item = value_at(b, key.next, level + 1)?
				$fields = $fields.append((key.value, item.value))
				$at = item.next
			}
			Ok({ value: Js.Obj($fields), next: $at })
		}
		6 => {
			if h.arg == 24 {
				inner = head(b, h.next)?
				if inner.major != 2 return Err(Bad(i))
				raw = take(b, inner.next, inner.arg)?
				Ok({ value: Js.Packed(raw), next: inner.next + inner.arg })
			} else if h.arg == 27 {
				generic(b, h.next)
			} else {
				Err(Bad(i))
			}
		}
		_ => match h.info {
			20 => Ok({ value: Js.Bool(Bool.False), next: h.next })
			21 => Ok({ value: Js.Bool(Bool.True), next: h.next })
			22 => Ok({ value: Js.Null, next: h.next })
			23 => Ok({ value: Js.Undefined, next: h.next })
			25 => Ok({ value: Js.Num(half(h.arg)), next: h.next })
			26 => Ok({ value: Js.Num(F32.from_bits(h.arg.to_u32_try() ?? 0).to_f64()), next: h.next })
			27 => Ok({ value: Js.Num(F64.from_bits(h.arg)), next: h.next })
			_ => Err(Bad(i))
		}
	}
}

# Tag 27: ["Ref", id] or ["Error", name, message].
generic : List(U8), U64 -> Try({ value : Js, next : U64 }, [Bad(U64)])
generic = |b, i| {
	arr = head(b, i)?
	if arr.major != 4 return Err(Bad(i))
	kind = head(b, arr.next)?
	if kind.major != 3 return Err(Bad(i))
	name = take(b, kind.next, kind.arg)?
	at = kind.next + kind.arg
	if arr.arg == 2 and name == "Ref".to_utf8() {
		id = head(b, at)?
		if id.major != 0 return Err(Bad(at))
		n = id.arg.to_u32_try() ? |_| Bad(at)
		Ok({ value: Js.Ref(n), next: id.next })
	} else if arr.arg == 3 and name == "Error".to_utf8() {
		e_name = text_at(b, at)?
		e_message = text_at(b, e_name.next)?
		Ok({ value: Js.Error(e_name.value, e_message.value), next: e_message.next })
	} else {
		Err(Bad(i))
	}
}

decode : List(U8) -> Try(Js, [Bad(U64)])
decode = |b| {
	v = value_at(b, 0, 0)?
	if v.next == b.len() Ok(v.value) else Err(Bad(v.next))
}

# ---- encode (the shortest head; floats as f64)

put_be : List(U8), U64, U64 -> List(U8)
put_be = |out, n, size| {
	var $o = out
	var $k = size
	while $k > 0 {
		$k = $k - 1
		var $d = n
		for _ in 0.U64.until($k) {
			$d = $d // 256
		}
		$o = $o.append(($d % 256).to_u8_wrap())
	}
	$o
}

put_head : List(U8), U8, U64 -> List(U8)
put_head = |out, major, n| {
	m = major * 32
	if n < 24 {
		out.append(m + n.to_u8_wrap())
	} else if n < 256 {
		put_be(out.append(m + 24), n, 1)
	} else if n < 65536 {
		put_be(out.append(m + 25), n, 2)
	} else if n < 4294967296 {
		put_be(out.append(m + 26), n, 4)
	} else {
		put_be(out.append(m + 27), n, 8)
	}
}

put_text : List(U8), Str -> List(U8)
put_text = |out, s| {
	raw = s.to_utf8()
	put_head(out, 3, raw.len()).concat(raw)
}

encode : List(U8), Js -> List(U8)
encode = |out, v| match v {
	Undefined => out.append(0xf7)
	Null => out.append(0xf6)
	Bool(x) => out.append(if x 0xf5 else 0xf4)
	Num(f) => put_be(out.append(0xfb), f.to_bits(), 8)
	Int(n) => if n >= 0 put_head(out, 0, n.to_u64_wrap()) else put_head(out, 1, (-1 - n).to_u64_wrap())
	Text(s) => put_text(out, s)
	Bytes(raw) => put_head(out, 2, raw.len()).concat(raw)
	Arr(items) => {
		var $o = put_head(out, 4, items.len())
		for item in items {
			$o = encode($o, item)
		}
		$o
	}
	Obj(fields) => {
		var $o = put_head(out, 5, fields.len())
		for field in fields {
			(k, x) = field
			$o = encode(put_text($o, k), x)
		}
		$o
	}
	Ref(id) => put_head(put_text(out.append(0xd8).append(27).append(0x82), "Ref"), 0, id.to_u64())
	Error(name, message) => put_text(put_text(put_text(out.append(0xd8).append(27).append(0x83), "Error"), name), message)
	Packed(raw) => put_head(out.append(0xd8).append(24), 2, raw.len()).concat(raw)
}

# ---- the comparison

u32_at : List(U8), U64 -> U64
u32_at = |b, i| {
	var $x = 0
	for k in [3, 2, 1, 0] {
		$x = $x * 256 + (b.get(i + k) ?? 0).to_u64()
	}
	$x
}

to_hex : List(U8) -> Str
to_hex = |b| {
	digits = "0123456789abcdef".to_utf8()
	var $o = []
	for x in b.sublist({ start: 0, len: 40 }) {
		$o = $o.append(digits.get((x // 16).to_u64()) ?? 0).append(digits.get((x % 16).to_u64()) ?? 0)
	}
	Str.from_utf8($o) ?? ""
}

main! = |_args| {
	var $i = 0.U64
	var $j = 0.U64
	var $n = 0.U64
	var $values = 0.U64
	var $errors = 0.U64
	var $bad = 0.U64
	while $i < corpus.len() {
		len = u32_at(corpus, $i)
		input = corpus.sublist({ start: $i + 4, len })
		$i = $i + 4 + len
		ok = (zig.get($j) ?? 0) == 1
		zlen = u32_at(zig, $j + 1)
		zbytes = zig.sublist({ start: $j + 5, len: zlen })
		$j = $j + 5 + zlen
		mine = match decode(input) {
			Ok(v) => Ok(encode([], v))
			Err(_) => Err({})
		}
		same = match mine {
			Ok(bytes) => {
				$values = $values + 1
				ok and bytes == zbytes
			}
			Err(_) => {
				$errors = $errors + 1
				!ok
			}
		}
		if !same {
			$bad = $bad + 1
			if $bad <= 5 {
				what = match mine {
					Ok(bytes) => "oracle ${to_hex(bytes)}"
					Err(_) => "oracle error"
				}
				zig_what = if ok "zig ${to_hex(zbytes)}" else "zig error"
				echo!("differ: input ${$n.to_str()}: ${to_hex(input)}: ${what}, ${zig_what}\n")
			}
		}
		$n = $n + 1
	}
	if $bad == 0 {
		echo!("PASS ${$n.to_str()} inputs, ${$values.to_str()} values, ${$errors.to_str()} errors\n")
	} else {
		echo!("FAIL ${$bad.to_str()} of ${$n.to_str()} inputs differ\n")
	}
	Ok({})
}
