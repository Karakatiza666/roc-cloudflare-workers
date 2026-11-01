app [main!] { pf: platform "./platform/main.roc" }

import pf.FallibleHost

main! = || {
	n : I128
	n = FallibleHost.json_input!({}).count_utf8_bytes().to_i128() - 18 # 3, not a constant
	"u8=${Str.inspect(n.to_u8_try())} u16=${Str.inspect(n.to_u16_try())} i8=${Str.inspect(n.to_i8_try())} i16=${Str.inspect(n.to_i16_try())} u32=${Str.inspect(n.to_u32_try())} i64=${Str.inspect(n.to_i64_try())}"
}
