app [] { pkg: "cbor-copy/src/main.roc" }

import pkg.Cbor

Row : { name : Str, id : I64 }

# [{"name": "a", "id": f64 2^53}]
float_big : List(U8)
float_big = [0x81, 0xa2, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x61, 0x61, 0x62, 0x69, 0x64, 0xfb, 0x43, 0x40, 0, 0, 0, 0, 0, 0]

# [{"name": "a", "id": "123"}]
text_id : List(U8)
text_id = [0x81, 0xa2, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x61, 0x61, 0x62, 0x69, 0x64, 0x63, 0x31, 0x32, 0x33]

# [{"name": "a"}]
missing : List(U8)
missing = [0x81, 0xa1, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x61, 0x61]

expect {
	r : Try(List(Row), _)
	r = Cbor.parse(float_big)
	r == Ok([{ name: "a", id: 9007199254740992 }])
}

expect {
	r : Try(List(Row), _)
	r = Cbor.parse(text_id)
	r == Err(InvalidCbor(12))
}

expect {
	r : Try(List(Row), _)
	r = Cbor.parse(missing)
	r == Err(MissingRequiredField("id"))
}
