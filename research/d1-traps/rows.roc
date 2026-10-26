app [event!] { pf: platform "../../platform/main.roc" }

## D1 row reads (v2 probe findings 30, 31): how roc-cbor 0.2.1 reads a NULL and a missing column into each field type.
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

# Try(a, [Null]): a NULL is Err(Null).
expect {
	r : Try({ a : Try(Str, [Null]) }, _)
	r = Cbor.parse(null_a)
	r == Ok({ a: Err(Null) })
}

# Try(a, [Null]) with no key: MissingRequiredField. So the platform cannot drop a NULL key from a row: this field type
# would break.
expect {
	r : Try({ a : Try(Str, [Null]) }, _)
	r = Cbor.parse(no_a)
	r == Err(MissingRequiredField("a"))
}

# Try(a, [Missing]) with no key, and with a NULL.
expect {
	r : Try({ a : Try(Str, [Missing]) }, _)
	r = Cbor.parse(no_a)
	r == Ok({ a: Err(Missing) })
}

expect {
	r : Try({ a : Try(Str, [Missing]) }, _)
	r = Cbor.parse(null_a)
	r == Err(InvalidCbor(3))
}

# Try(a, [Null, Missing]) does not compile: "requires the parser_for method ... { a: Try(Str, [Missing, Null]) }".

# An optional field: no key is absent, a NULL is an error (the Str parser sees null).
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
	r.is_err()
}

# Bool from 0: parse_bool reads only 0xf4 and 0xf5.
expect {
	r : Try({ a : Bool }, _)
	r = Cbor.parse(zero_a)
	r == Err(InvalidCbor(3))
}
