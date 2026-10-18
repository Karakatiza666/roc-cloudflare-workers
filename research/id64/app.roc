app [event!] { pf: platform "../../platform/main.roc" }

## Probe app of research/id64: the tests of `Id64` and a round trip through the platform row parser.
import pf.Worker
import pf.Cbor
import pf.Sql
import Id64

worker = Worker.{ fetch!: |_req| crash "unused" }

event! = |e| worker.event!(e)

expect Id64.from_u64(5).to_u64() == 5

big : U64
big = 0xFFFF_FFFF_FFFF_FFFF

# Construct and read back. R-ID1: the whole U64 range maps with no loss.
expect [0.U64, 1, 0x7FFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000, big].all(|n| Id64.from_u64(n).to_u64() == n)
expect Id64.from_u64(0x8000_0000_0000_0000).to_i64() == I64.lowest
expect Id64.from_u64(big).to_i64() == -1
expect Id64.from_i64(-1).to_u64() == big
expect Id64.from_i64(-1) == Id64.from_u64(big)

# Bytes, big-endian.
expect Id64.from_bytes([0x80, 0, 0, 0, 0, 0, 0, 1]) == Ok(Id64.from_u64(0x8000_0000_0000_0001))
expect Id64.from_u64(0x0102_0304_0506_0708).to_bytes() == [1, 2, 3, 4, 5, 6, 7, 8]
expect Id64.from_u64(big).to_bytes() == [255, 255, 255, 255, 255, 255, 255, 255]
expect Id64.from_bytes([1, 2, 3]) == Err(BadLength)

# Text.
expect Id64.from_u64(big).to_str() == "-1"
expect Id64.from_str("-9223372036854775808") == Ok(Id64.from_i64(I64.lowest))
expect Id64.from_str("9223372036854775807") == Ok(Id64.from_i64(I64.highest))
expect ["18446744073709551616", "-9223372036854775809", "+1", "01", "-0", "", "abc", " 1", "1.0", "-"].all(|t| Id64.from_str(t) == Err(BadId))
# U64 text (from a browser) and I64 text (from CAST) of the same id.
expect Id64.from_str("18446744073709551615") == Ok(Id64.from_u64(big))
expect Id64.from_str("9223372036854775808") == Ok(Id64.from_i64(I64.lowest))
expect Id64.from_str("5") == Ok(Id64.from_u64(5))
expect Id64.from_u64(big).to_u64_str() == "18446744073709551615"
expect Id64.from_u64(5).to_u64_str() == "5"

# Equality, hash, inspect.
expect Id64.from_u64(7) != Id64.from_u64(8)
expect {
	d = Dict.empty().insert(Id64.from_u64(big), "a").insert(Id64.from_u64(1), "b")
	d.get(Id64.from_i64(-1)) == Ok("a") and d.get(Id64.from_u64(2)) == Err(KeyNotFound)
}
expect Str.inspect(Id64.from_u64(big)) == "Id64(-1)"

# CBOR write: the item is the text of the I64 (R-IK2).
expect Cbor.encode(Id64.from_u64(big)) == Cbor.encode("-1")
expect Cbor.encode({ id: Id64.from_u64(5) }) == Cbor.encode({ id: "5" })
# As an item of a tuple: a SQL parameter list `(id, now)`.
expect Cbor.encode((Id64.from_u64(5), 7.I64)) == Cbor.encode(("5", 7.I64))

Row : { id : Id64, n : I64 }

# CBOR read, as the row parser of the platform does (`int_from_text`): the text of `CAST(id AS TEXT)`.
expect {
	raw = Cbor.encode({ id: "-1", n: 3.I64 })
	got : Try(Row, _)
	got = Cbor.parse_with(raw, { fields: Snake, int_from_text: Bool.True })
	got == Ok({ id: Id64.from_u64(big), n: 3 })
}
# The same with no `int_from_text`: the text is read by the type of the id, not by the option.
expect {
	raw = Cbor.encode({ id: "-1", n: 3.I64 })
	got : Try(Row, _)
	got = Cbor.parse(raw)
	got == Ok({ id: Id64.from_u64(big), n: 3 })
}
# A CBOR integer, positive and negative.
expect {
	got : Try(Row, _)
	got = Cbor.parse(Cbor.encode({ id: 7.I64, n: 3.I64 }))
	got == Ok({ id: Id64.from_u64(7), n: 3 })
}
expect {
	got : Try(Row, _)
	got = Cbor.parse(Cbor.encode({ id: -7.I64, n: 3.I64 }))
	got == Ok({ id: Id64.from_i64(-7), n: 3 })
}
# Round trip of a value above 2^63 as U64, in a row and in a list.
expect {
	id = Id64.from_u64(0xDEAD_BEEF_0000_0001)
	got : Try(List(Row), _)
	got = Cbor.parse_with(Cbor.encode([{ id, n: 1.I64 }]), { fields: Snake, int_from_text: Bool.True })
	got == Ok([{ id, n: 1 }]) and got.map_ok(|rows| rows.map(|r| r.id.to_u64())) == Ok([0xDEAD_BEEF_0000_0001])
}
# A float of size 2^53 or more (a rounded D1 integer) is an error, not a wrong id (R-ID2).
expect {
	raw = Cbor.encode({ id: 1.0e19.F64, n: 3.I64 })
	got : Try(Row, _)
	got = Cbor.parse_with(raw, { fields: Snake, int_from_text: Bool.True })
	got.is_err()
}
# Bad text and text out of range are errors.
expect ["18446744073709551616", "01", "x", ""].all(
	|t| {
		got : Try(Row, _)
		got = Cbor.parse_with(Cbor.encode({ id: t, n: 3.I64 }), { fields: Snake, int_from_text: Bool.True })
		got.is_err()
	},
)
# A tuple row, as `D1.all_tuples!` reads.
expect {
	got : Try((Id64, I64), _)
	got = Cbor.parse_with(Cbor.encode(("-1", 3.I64)), { fields: Snake, int_from_text: Bool.True })
	got == Ok((Id64.from_u64(big), 3))
}

# JSON (browser): a response field is `Id64.Web`, with the U64 text. A request field is `Id64` or `Id64.Web`, with U64 or I64 text.
# A bare `Id64` in a JSON value does not compile (must-not-compile.sh).
JsonRow : { id : Id64.Web }

expect Encoding.Json.to_str({ id: Id64.from_u64(big).to_web() }) == "{\"id\":\"18446744073709551615\"}"
expect Encoding.Json.to_str({ id: Id64.from_u64(5).to_web() }) == "{\"id\":\"5\"}"
expect {
	got : Try({ id : Id64 }, _)
	got = Encoding.Json.parse("{\"id\":\"18446744073709551615\"}")
	got == Ok({ id: Id64.from_u64(big) })
}
expect {
	got : Try({ id : Id64 }, _)
	got = Encoding.Json.parse("{\"id\":\"-1\"}")
	got == Ok({ id: Id64.from_u64(big) })
}
expect {
	got : Try(JsonRow, _)
	got = Encoding.Json.parse("{\"id\":\"18446744073709551615\"}")
	got.map_ok(|r| Id64.from_web(r.id)) == Ok({ id: Id64.from_u64(big) }.id)
}
expect Str.inspect(Id64.from_u64(big).to_web()) == "Id64.Web(18446744073709551615)"
# Web in CBOR also writes the U64 text (it is for a browser, not for SQL).
expect Cbor.encode(Id64.from_u64(big).to_web()) == Cbor.encode("18446744073709551615")
# Full path: a SQL row (I64 text) to a browser payload (U64 text) with one call, `to_web`.
expect {
	row : Try(Row, _)
	row = Cbor.parse_with(Cbor.encode({ id: "-1", n: 3.I64 }), { fields: Snake, int_from_text: Bool.True })
	row.map_ok(|r| Encoding.Json.to_str({ id: r.id.to_web() })) == Ok("{\"id\":\"18446744073709551615\"}")
}
