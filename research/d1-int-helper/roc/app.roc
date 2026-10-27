app [event!] { pf: platform "../../../platform/main.roc" }

## Probe C (number-like type) and probe A (plain I64), with the row parser options of the platform
## (`Cbor.parse_with(bytes, { int_from_text: Bool.True })`, as `SqlRules.typed`). The CBOR bytes are what
## `pf.pack` sends for a D1 row: {"id": <item>}. `roc test`.
import pf.Worker
import pf.Cbor
import DbInt

worker = Worker.new({ fetch!: |_req| crash "unused" })

event! = |e| worker.event!(e)


# {"id": "9007199254740993"}: what CAST(id AS TEXT) gives for 2^53 + 1.
cast_text : List(U8)
cast_text = [0xa1, 0x62, 0x69, 0x64, 0x70].concat(Str.to_utf8("9007199254740993"))

# {"id": 9007199254740992.0}: what D1 gives for 2^53 + 1 with no CAST (f64, rounded).
rounded : List(U8)
rounded = [0xa1, 0x62, 0x69, 0x64, 0xfb, 0x43, 0x40, 0, 0, 0, 0, 0, 0]

# {"id": 5}: a small id with no CAST (pf.pack writes a safe integer as a CBOR integer).
small : List(U8)
small = [0xa1, 0x62, 0x69, 0x64, 0x05]

# ---- C: DbInt ----

# Literals and operators, a literal on either side.
expect {
	x : DbInt
	x = 41
	y = x + 1
	y == 42 and x > 0 and 0 < x and 42 == y and x != 5 and -x == -41 and x * 2 - 40 == 42 and x // 2 == 20 and x % 2 == 1
}

# A literal suffix.
expect 7.DbInt + 1 == 8

# Read: CAST text gives the exact value.
expect {
	r : Try({ id : DbInt }, _)
	r = Cbor.parse_with(cast_text, { int_from_text: Bool.True })
	match r {
		Ok(row) => row.id == 9007199254740993 and row.id + 1 > 9007199254740993
		Err(_) => Bool.False
	}
}

# Read: no CAST, a big id: an error (rounded f64).
expect {
	r : Try({ id : DbInt }, _)
	r = Cbor.parse_with(rounded, { int_from_text: Bool.True })
	r.is_err()
}

# Read: no CAST, a small id: also an error. The missing CAST shows at the first test.
expect {
	r : Try({ id : DbInt }, _)
	r = Cbor.parse_with(small, { int_from_text: Bool.True })
	r.is_err()
}

# Write: a CBOR integer (the platform JS binds 2^53 + 1 as text).
expect {
	x : DbInt
	x = 9007199254740993
	Cbor.encode([x]) == Cbor.encode([9007199254740993.I64])
}

# Dict key, inspect.
expect {
	x : DbInt
	x = 3
	Dict.empty().insert(x, "a").get(3) == Ok("a") and Str.inspect(x) == "3"
}

# ---- A: plain I64 (today) ----

# Read with CAST: exact.
expect {
	r : Try({ id : I64 }, _)
	r = Cbor.parse_with(cast_text, { int_from_text: Bool.True })
	r == Ok({ id: 9007199254740993 })
}

# Read with no CAST, a big id: an error, not a rounded value.
expect {
	r : Try({ id : I64 }, _)
	r = Cbor.parse_with(rounded, { int_from_text: Bool.True })
	r.is_err()
}

# Read with no CAST, a small id: Ok. The missing CAST does not show until an id reaches 2^53.
expect {
	r : Try({ id : I64 }, _)
	r = Cbor.parse_with(small, { int_from_text: Bool.True })
	r == Ok({ id: 5 })
}

# I64 already has literals and operators on either side.
expect {
	x : I64
	x = 41
	x + 1 == 42 and 1 + x == 42 and x > 0 and 0 < x
}

# ---- silent traps of A (and of C: they are outside the integer field) ----

# An F64 field reads the rounded value with no error: 2^53 + 1 is 2^53.
expect {
	r : Try({ id : F64 }, _)
	r = Cbor.parse_with(rounded, { int_from_text: Bool.True })
	r == Ok({ id: 9007199254740992.0 })
}

# A Dec field reads the rounded value with no error.
expect {
	r : Try({ id : Dec }, _)
	r = Cbor.parse_with(rounded, { int_from_text: Bool.True })
	r == Ok({ id: 9007199254740992 })
}

# A Str field reads the CAST text (no error, no number).
expect {
	r : Try({ id : Str }, _)
	r = Cbor.parse_with(cast_text, { int_from_text: Bool.True })
	r == Ok({ id: "9007199254740993" })
}

# C: a literal on the left works when the result has an annotation.
expect {
	x : DbInt
	x = 41
	y : DbInt
	y = 1 + x
	y == 42
}

# C: JSON writes a number. A browser (JSON.parse) rounds it above 2^53, with no error (Id64.Web writes text).
expect {
	x : DbInt
	x = 9007199254740993
	Encoding.Json.to_str({ id: x }) == "{\"id\":9007199254740993}"
}
