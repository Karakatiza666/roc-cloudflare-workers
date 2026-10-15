## Control: a list of Secret. The compiler rejects the encode (correct).
import Secret

main! = |_args| {
	echo!(Json.to_str([Secret.from_str("hunter2")]))
	Ok({})
}
