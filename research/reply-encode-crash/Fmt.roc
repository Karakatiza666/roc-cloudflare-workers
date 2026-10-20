## A tiny format: it writes a tag name and a U64.
Fmt := [Fmt].{
	a.Writable :
		where [
			a.encoder_for : Fmt -> (a, List(U8) -> Try(List(U8), [])),
		]

	encode : a -> List(U8) where [a.Writable]
	encode = |value| {
		Shape : a
		enc = Shape.encoder_for(Fmt.Fmt)
		match enc(value, []) {
			Ok(out) => out
		}
	}

	encode_u64 : U64, List(U8) -> Try(List(U8), [])
	encode_u64 = |value, out| Ok(out.append(value.to_u8_wrap()))

	encode_tag : List(U8), Str, U64, ({ out : List(U8), n : U64 }, ({ out : List(U8), n : U64 }, (List(U8) -> Try(List(U8), err)) -> Try({ out : List(U8), n : U64 }, err)) -> Try({ out : List(U8), n : U64 }, err)) -> Try(List(U8), err)
	encode_tag = |out, tag, _count, write_payloads| {
		done = write_payloads({ out: out.concat(tag.to_utf8()), n: 0 }, |c, write| Ok({ out: write(c.out)?, n: c.n + 1 }))?
		Ok(done.out)
	}
}
