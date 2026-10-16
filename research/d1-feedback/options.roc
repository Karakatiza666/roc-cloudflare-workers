app [] { pkg: "cbor-copy/src/main.roc" }

import pkg.Cbor

Row : { name : Str, id : I64 }

# [{"name": "a", "id": f64 2^53}]
float_big : List(U8)
float_big = [0x81, 0xa2, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x61, 0x61, 0x62, 0x69, 0x64, 0xfb, 0x43, 0x40, 0, 0, 0, 0, 0, 0]

# f64 2^53 - 1, f64 -(2^53 - 1), f64 -2^53
f_safe_max : List(U8)
f_safe_max = [0xfb, 0x43, 0x3f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
f_safe_min : List(U8)
f_safe_min = [0xfb, 0xc3, 0x3f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
f_neg_big : List(U8)
f_neg_big = [0xfb, 0xc3, 0x40, 0, 0, 0, 0, 0, 0]

# The CBOR text of s.
txt : Str -> List(U8)
txt = |s| [0x60 + s.to_utf8().len().to_u8_wrap()].concat(s.to_utf8())

ints : Cbor.Options
ints = { fields: Snake, int_from_text: Bool.True }

# Float rule (default)
expect {
	r : Try(List(Row), _)
	r = Cbor.parse(float_big)
	r == Err(InvalidCbor(12))
}
expect {
	r : Try(I64, _)
	r = Cbor.parse(f_safe_max)
	r == Ok(9007199254740991)
}
expect {
	r : Try(I64, _)
	r = Cbor.parse(f_safe_min)
	r == Ok(-9007199254740991)
}
expect {
	r : Try(I64, _)
	r = Cbor.parse(f_neg_big)
	r == Err(InvalidCbor(0))
}
expect {
	r : Try(F64, _)
	r = Cbor.parse(float_big.drop_first(12))
	r == Ok(9007199254740992.0)
}

# Text rule
expect {
	r : Try(I64, _)
	r = Cbor.parse_with(txt("-9223372036854775808"), ints)
	r == Ok(-9223372036854775808)
}
expect {
	r : Try(I64, _)
	r = Cbor.parse_with(txt("9223372036854775807"), ints)
	r == Ok(9223372036854775807)
}
expect {
	r : Try(I64, _)
	r = Cbor.parse_with(txt("9223372036854775808"), ints)
	r == Err(InvalidCbor(0))
}
expect {
	r : Try(U8, _)
	r = Cbor.parse_with(txt("256"), ints)
	r == Err(InvalidCbor(0))
}
expect {
	r : Try(U64, _)
	r = Cbor.parse_with(txt("-1"), ints)
	r == Err(InvalidCbor(0))
}
expect {
	r : Try(I64, _)
	r = Cbor.parse_with(txt("0"), ints)
	r == Ok(0)
}
expect ["-0", "01", "+1", " 1", "1 ", "1.0", "1e3", "", "-", "0x10", "123456789012345678901"].all(
	|s| {
		r : Try(I64, _)
		r = Cbor.parse_with(txt(s), ints)
		r == Err(InvalidCbor(0))
	},
)
expect {
	r : Try(I64, _)
	r = Cbor.parse(txt("12"))
	r == Err(InvalidCbor(0))
}
expect {
	r : Try(Str, _)
	r = Cbor.parse_with(txt("12"), ints)
	r == Ok("12")
}

# path_at
expect Cbor.path_at(float_big, 12) == Ok([Index(0), Key("id")])
expect Cbor.path_at(float_big, 7) == Ok([Index(0), Key("name")])
expect Cbor.path_at(float_big, 0) == Ok([])
expect Cbor.path_at(float_big, 13) == Err(NotFound)
expect Cbor.path_at(float_big, 99) == Err(NotFound)
