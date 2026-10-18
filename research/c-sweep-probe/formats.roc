app [event!] { pf: platform "../../platform/main.roc" }

## Issue 8: what survives a round trip in the two formats of the platform, in Roc (`roc test`). The JS side is in
## MODULES.md 1, "Formats of typed data".
import pf.Worker
import pf.Cbor
import pf.Id64

worker = Worker.new({ fetch!: |_req| crash "unused" })

event! = |e| worker.event!(e)

big : U64
big = 9_007_199_254_740_993

# An integer above 2^53: exact in CBOR and in JSON (Roc reads its own digits).
expect {
	back : Try({ n : U64 }, _)
	back = Cbor.parse(Cbor.encode({ n: big }))
	back == Ok({ n: big })
}

expect {
	back : Try({ n : U64 }, _)
	back = Json.parse(Json.to_str({ n: big }))
	back == Ok({ n: big })
}

# F64 NaN: CBOR keeps it (f64 bits). JSON cannot write it.
expect {
	nan = 0.0.F64 / 0.0.F64
	back : Try({ x : F64 }, _)
	back = Cbor.parse(Cbor.encode({ x: nan }))
	match back {
		Ok({ x }) => x.is_nan()
		Err(_) => Bool.False
	}
}

expect {
	nan = 0.0.F64 / 0.0.F64
	Json.to_str_try({ x: nan }).is_err()
}

# Dec in JSON: exact in Roc.
expect {
	d : Dec
	d = 0.1
	back : Try({ d : Dec }, _)
	back = Json.parse(Json.to_str({ d: d }))
	back == Ok({ d: d })
}

# Dec in CBOR does not compile: roc-cbor 0.1.0 has no `encode_dec` and no `parse_dec` (checked 2026-10-18).

# Id64 in CBOR: the I64 text.
expect {
	id = Id64.from_u64(18_446_744_073_709_551_615)
	back : Try({ id : Id64 }, _)
	back = Cbor.parse(Cbor.encode({ id: id }))
	back == Ok({ id: id })
}

# List(U8) and Cbor.Bytes: both come back.
expect {
	a : List(U8)
	a = [1, 2]
	back : Try({ a : List(U8), b : Cbor.Bytes }, _)
	back = Cbor.parse(Cbor.encode({ a, b: Cbor.bytes([3]) }))
	match back {
		Ok(r) => r.a == a and r.b.to_list() == [3]
		Err(_) => Bool.False
	}
}
