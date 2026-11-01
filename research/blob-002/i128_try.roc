## The smallest repro: `I128.to_u8_try` of 3 is `Err(OutOfRange)` with `--opt=dev` (wasm32), `Ok(3)` with `--opt=speed`.
main! = |args| {
	n : I128
	n = args.len().to_i128() + 2
	echo!("u8=${Str.inspect(n.to_u8_try())} u16=${Str.inspect(n.to_u16_try())} i8=${Str.inspect(n.to_i8_try())} i16=${Str.inspect(n.to_i16_try())} u32=${Str.inspect(n.to_u32_try())}\n")
	Ok({})
}
