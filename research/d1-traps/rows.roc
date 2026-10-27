app [event!] { pf: platform "../../platform/main.roc" }

## D1 row reads (v2 probe findings 30, 31): how roc-cbor 0.2.2 reads a NULL and a missing column into each field type.
## `roc test --no-cache`. {"a": null} is a1 61 61 f6, {} is a0, {"a": 0} is a1 61 61 00.
import pf.Worker
import pf.Cbor

worker = Worker.new({ fetch!: |_req| crash "unused" })

event! = |e| worker.event!(e)

null_a : List(U8)
null_a = [0xa1, 0x61, 0x61, 0xf6]

no_a : List(U8)
no_a = [0xa0]

zero_a : List(U8)
zero_a = [0xa1, 0x61, 0x61, 0x00]

# roc-cbor 0.2.2: a null value in a map read as a record is the same as no key.
# Try(a, [Null]) is a required field: a NULL is MissingRequiredField (0.2.1 gave Err(Null)).
expect {
	r : Try({ a : Try(Str, [Null]) }, _)
	r = Cbor.parse(null_a)
	r == Err(MissingRequiredField("a"))
}

# Try(a, [Null]) with no key: MissingRequiredField, the same.
expect {
	r : Try({ a : Try(Str, [Null]) }, _)
	r = Cbor.parse(no_a)
	r == Err(MissingRequiredField("a"))
}

# Try(a, [Missing]) with no key, and with a NULL (0.2.1 gave InvalidCbor(3)): Err(Missing).
expect {
	r : Try({ a : Try(Str, [Missing]) }, _)
	r = Cbor.parse(no_a)
	r == Ok({ a: Err(Missing) })
}

expect {
	r : Try({ a : Try(Str, [Missing]) }, _)
	r = Cbor.parse(null_a)
	r == Ok({ a: Err(Missing) })
}

# Try(a, [Null, Missing]) does not compile: "requires the parser_for method ... { a: Try(Str, [Missing, Null]) }".

# An optional field: no key and a NULL are both absent (0.2.1: a NULL was an error).
expect {
	r : Try({ a ?: Str, b : U8 }, _)
	r = Cbor.parse([0xa1, 0x61, 0x62, 0x01])
	match r {
		Ok(v) =>
			match v.?a {
				Ok(_) => Bool.False
				Err(_) => Bool.True
			}
		Err(_) => Bool.False
	}
}

expect {
	r : Try({ a ?: Str, b : U8 }, _)
	r = Cbor.parse([0xa2, 0x61, 0x61, 0xf6, 0x61, 0x62, 0x01])
	match r {
		Ok(v) => v.b == 1 and v.?a.is_err()
		Err(_) => Bool.False
	}
}

# A null outside a record: a list item reads into Try(a, [Null]) only.
expect {
	r : Try(List(Try(Str, [Null])), _)
	r = Cbor.parse([0x81, 0xf6])
	r == Ok([Err(Null)])
}

expect {
	r : Try(List(Str), _)
	r = Cbor.parse([0x81, 0xf6])
	r == Err(InvalidCbor(1))
}

# Err(Null) in a record field writes no key (0.2.1 wrote null). It reads back as Err(Missing).
expect {
	nullable : Try(Str, [Null])
	nullable = Err(Null)
	Cbor.encode({ a: nullable, b: 1.U8 }) == [0xa1, 0x61, 0x62, 0x01]
}

# Bool from 0 and 1 (0.2.1: InvalidCbor(3)). 2 is an error.
expect {
	r : Try({ a : Bool }, _)
	r = Cbor.parse(zero_a)
	r == Ok({ a: Bool.False })
}

expect {
	r : Try({ a : Bool }, _)
	r = Cbor.parse([0xa1, 0x61, 0x61, 0x01])
	r == Ok({ a: Bool.True })
}

expect {
	r : Try({ a : Bool }, _)
	r = Cbor.parse([0xa1, 0x61, 0x61, 0x02])
	r == Err(InvalidCbor(3))
}
