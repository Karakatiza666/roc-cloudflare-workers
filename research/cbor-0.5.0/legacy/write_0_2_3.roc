app [] { cbor: "https://github.com/Karakatiza666/roc-cbor/releases/download/0.2.3/GkHriTGSE8ww1h2HvUL3GS6x1t2keTW13KQazoUZh4Uc.tar.zst" }

# The bytes that roc-cbor 0.2.3 (the version of platform release 0.0.9) writes. platform/Cbor.roc tests
# `legacy_0_2` with these bytes. The 0.2.3 release (URL in the header).
# Run: roc test research/cbor-0.5.0/legacy/write_0_2_3.roc. Each expect pins the bytes.
import cbor.Cbor

# Short containers have the shortest head. A List(U8) is an array. An Err(Null) field is not written.
expect {
	Old : { name : Str, data : List(U8), on : Bool, note : Try(Str, [Null]), price : Dec, items : List({ n : I64 }) }
	value : Old
	value = { name: "a", data: [1, 2], on: Bool.True, note: Err(Null), price: 1.5, items: [{ n: 300 }] }
	Cbor.encode(value) == [165, 100, 100, 97, 116, 97, 130, 1, 2, 101, 105, 116, 101, 109, 115, 129, 161, 97, 110, 25, 1, 44, 100, 110, 97, 109, 101, 97, 97, 98, 111, 110, 245, 101, 112, 114, 105, 99, 101, 196, 130, 32, 15]
}

# An array or a map of 24 items or more has a head of 3 bytes (0x99 0x00 0x18): not the shortest head (0x98 0x18).
expect Cbor.encode({ data: List.repeat(7.U8, 24), n: 1.I64 }) == [0xa2, 0x64, 0x64, 0x61, 0x74, 0x61, 0x99, 0x00, 0x18].concat(List.repeat(7, 24)).concat([0x61, 0x6e, 0x01])
