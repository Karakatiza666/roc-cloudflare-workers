## Bug: a tag payload of the type Secret. It compiles and writes the hidden text.
import Secret

main! = |_args| {
	v : [Token(Secret)]
	v = Token(Secret.from_str("hunter2"))
	echo!(Json.to_str(v))
	Ok({})
}
