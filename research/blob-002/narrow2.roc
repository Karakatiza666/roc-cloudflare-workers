app [event!] { pf: platform "../../platform/main.roc" }

## Narrow more: the `to_<T>_try` of an `I128`, no CBOR. `n` comes from the request so the compiler does not fold it.
import pf.Worker
import pf.Request
import pf.Response
import pf.Cbor

fetch! : Request => Try(Response, _)
fetch! = |req| {
	n : I128
	n = req.segments().len().to_i128() + 3
	u8 = n.to_u8_try()
	u16 = n.to_u16_try()
	u32 = n.to_u32_try()
	u64 = n.to_u64_try()
	i8 = n.to_i8_try()
	i16 = n.to_i16_try()
	i32 = n.to_i32_try()
	i64 = n.to_i64_try()
	m : I64
	m = req.segments().len().to_i64_wrap() + 3
	m8 = m.to_u8_try()
	p16 : Try(U16, _)
	p16 = Cbor.parse([0x03])
	p32 : Try(U32, _)
	p32 = Cbor.parse([0x03])
	pi8 : Try(I8, _)
	pi8 = Cbor.parse([0x03])
	Ok(Response.from_text(200, "u8=${Str.inspect(u8)} u16=${Str.inspect(u16)} u32=${Str.inspect(u32)} u64=${Str.inspect(u64)} i8=${Str.inspect(i8)} i16=${Str.inspect(i16)} i32=${Str.inspect(i32)} i64=${Str.inspect(i64)} i64->u8=${Str.inspect(m8)} parse u16=${Str.inspect(p16)} u32=${Str.inspect(p32)} i8=${Str.inspect(pi8)}"))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
