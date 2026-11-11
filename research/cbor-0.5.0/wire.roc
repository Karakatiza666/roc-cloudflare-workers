app [] { cbor: "https://github.com/Karakatiza666/roc-cbor/releases/download/0.5.0/B5U2mPsWTtuxfCRMzqQxio2ecDv7CAzCoyEMENMh4FNF.tar.zst" }

# Wire probes of roc-cbor 0.5.0 against the bytes that the JS shim writes (research/cbor-0.5.0/js-bytes.mjs).
# Run: roc test research/cbor-0.5.0/wire.roc. Each expect states the behavior that this probe found.
import cbor.Cbor

# A JS Number with no fraction is a CBOR integer. An F64 field reads it with the strict reader.
expect {
	r : Try({ r : F64 }, _)
	r = Cbor.parse([0xa1, 0x61, 0x72, 0x03])
	r == Ok({ r: 3.0 })
}

# JS writes each float as f64 (not the shortest). The strict reader reads it.
expect {
	r : Try({ r : F64 }, _)
	r = Cbor.parse([0xa1, 0x61, 0x72, 0xfb, 0x40, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
	r == Ok({ r: 2.5 })
}

# JS NaN (f64 7ff8...) into an F64.
expect {
	r : Try({ r : F64 }, _)
	r = Cbor.parse([0xa1, 0x61, 0x72, 0xfb, 0x7f, 0xf8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
	match r {
		Ok(v) => v.r.is_nan()
		Err(_) => Bool.False
	}
}

# JS `{ a: undefined }`: an error for an optional field with the strict reader.
expect {
	r : Try({ a ?: Str }, _)
	r = Cbor.parse([0xa1, 0x61, 0x61, 0xf7])
	r.is_err()
}

# The same with UndefinedAsNull and NullAsAbsent (in sql_rows): the field is absent.
expect {
	r : Try({ a ?: Str }, _)
	r = Cbor.parse_with([0xa1, 0x61, 0x61, 0xf7], { allow: [UndefinedAsNull, NullAsAbsent] })
	r.map_ok(|v| v.?a.is_err()) == Ok(Bool.True)
}

# JS writes a Number of 2^53 or more as f64. An I64 field: an error, also with FloatToInt (2^60 is above 2^53 - 1).
expect {
	r : Try({ n : I64 }, _)
	r = Cbor.parse_with([0xa1, 0x61, 0x6e, 0xfb, 0x43, 0xb0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], { allow: [FloatToInt] })
	r.is_err()
}

# A JS array of numbers (a D1 BLOB, or a List(U8) that 0.2.3 wrote) into a List(U8): strict error, Ok with BytesFromArray.
expect {
	r : Try({ b : List(U8) }, _)
	r = Cbor.parse([0xa1, 0x61, 0x62, 0x83, 0x01, 0x02, 0x18, 0xff])
	r.is_err()
}
expect {
	r : Try({ b : List(U8) }, _)
	r = Cbor.parse_with([0xa1, 0x61, 0x62, 0x83, 0x01, 0x02, 0x18, 0xff], { allow: [BytesFromArray] })
	r == Ok({ b: [1, 2, 255] })
}

# A JS list of 30 numbers: shortest head 0x98 0x1e. Strict Ok.
expect {
	xs : List(U64)
	xs = List.repeat(300, 30)
	r : Try({ xs : List(U64) }, _)
	r = Cbor.parse(Cbor.encode({ xs: xs }))
	r == Ok({ xs: xs })
}

# A list of 24 items that roc-cbor 0.2.3 wrote (head 0x99 0x00 0x18): strict error, Ok with PaddedNumbers.
old_24 : List(U8)
old_24 = [0x99, 0x00, 0x18].concat(List.repeat(0x01, 24))

expect {
	r : Try(List(U8), _)
	r = Cbor.parse(old_24)
	r.is_err()
}
expect {
	r : Try(List(U64), _)
	r = Cbor.parse_with(old_24, { allow: [PaddedNumbers] })
	r == Ok(List.repeat(1, 24))
}

# What 0.5.0 writes and JS reads (js-bytes.mjs <hex>): an F64 2.5 is f16, a List(U8) is a byte string, Err(Null) in a record is null.
expect Cbor.encode(2.5.F64) == [0xf9, 0x41, 0x00]
expect Cbor.encode(1.1.F32) == [0xfa, 0x3f, 0x8c, 0xcc, 0xcd]
expect Cbor.encode({ b: [1.U8, 2] }) == [0xa1, 0x61, 0x62, 0x42, 0x01, 0x02]
expect {
	v : { a : Try(Str, [Null]) }
	v = { a: Err(Null) }
	Cbor.encode(v) == [0xa1, 0x61, 0x61, 0xf6]
}

# IntFromText (roc-cbor 0.5.0) reads up to 39 digits for U128 and I128: decimal text above 2^64 and below -2^63 (the JSON
# form of `pf.plain`) reads. 40 digits, a sign on a U128 and a value out of range do not.
expect {
	r : Try(U128, _)
	r = Cbor.parse_with(Cbor.encode("1267650600228229401496703205376"), { allow: [IntFromText] })
	r == Ok(1_267_650_600_228_229_401_496_703_205_376)
}
expect {
	r : Try(I128, _)
	r = Cbor.parse_with(Cbor.encode("-170141183460469231731687303715884105728"), { allow: [IntFromText] })
	r == Ok(-170_141_183_460_469_231_731_687_303_715_884_105_728)
}
expect {
	r : Try(U128, _)
	r = Cbor.parse_with(Cbor.encode("340282366920938463463374607431768211456"), { allow: [IntFromText] })
	r.is_err()
}
expect {
	r : Try(U128, _)
	r = Cbor.parse_with(Cbor.encode("-1"), { allow: [IntFromText] })
	r.is_err()
}
# Out of range, 39 and 40 digits: all errors. (The U128 test above that reads Ok has 31 digits, 2^100.)
expect {
	r : Try(U128, _)
	r = Cbor.parse_with(Cbor.encode("3402823669209384634633746074317682114550"), { allow: [IntFromText] })
	r.is_err()
}
expect {
	r : Try(U128, _)
	r = Cbor.parse_with(Cbor.encode("9999999999999999999999999999999999999999"), { allow: [IntFromText] })
	r.is_err()
}
expect {
	r : Try(I128, _)
	r = Cbor.parse_with(Cbor.encode("170141183460469231731687303715884105728"), { allow: [IntFromText] })
	r.is_err()
}
expect {
	r : Try(I128, _)
	r = Cbor.parse_with(Cbor.encode("-170141183460469231731687303715884105729"), { allow: [IntFromText] })
	r.is_err()
}
expect {
	r : Try(I128, _)
	r = Cbor.parse_with(Cbor.encode("-1701411834604692317316873037158841057280"), { allow: [IntFromText] })
	r.is_err()
}
expect {
	r : Try(I128, _)
	r = Cbor.parse_with(Cbor.encode("1701411834604692317316873037158841057270"), { allow: [IntFromText] })
	r.is_err()
}
expect {
	r : Try(U128, _)
	r = Cbor.parse_with(Cbor.encode("340282366920938463463374607431768211455"), { allow: [IntFromText] })
	r == Ok(U128.highest)
}
expect {
	r : Try(I128, _)
	r = Cbor.parse_with(Cbor.encode("170141183460469231731687303715884105727"), { allow: [IntFromText] })
	r == Ok(I128.highest)
}
# BytesFromBase64: List(U8) and Cbor.Bytes read padded canonical base64 text; not without the leniency; not unpadded.
expect {
	r : Try(List(U8), _)
	r = Cbor.parse_with(Cbor.encode("AQL/"), { allow: [BytesFromBase64] })
	r == Ok([1, 2, 255])
}
expect {
	r : Try(Cbor.Bytes, _)
	r = Cbor.parse_with(Cbor.encode("AID+"), { allow: [BytesFromBase64] })
	r.map_ok(|b| b.to_list()) == Ok([0, 128, 254])
}
expect {
	r : Try(List(U8), _)
	r = Cbor.parse(Cbor.encode("AQL/"))
	r.is_err()
}
expect {
	r : Try(List(U8), _)
	r = Cbor.parse_with(Cbor.encode("AQI"), { allow: [BytesFromBase64] })
	r.is_err()
}
expect {
	r : Try(List(U8), _)
	r = Cbor.parse_with(Cbor.encode("AQL/"), { allow: Cbor.sql_rows })
	r.is_err()
}
expect {
	r : Try(U128, _)
	r = Cbor.parse_with(Cbor.encode("18446744073709551615"), { allow: [IntFromText] })
	r == Ok(18_446_744_073_709_551_615)
}
