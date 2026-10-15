## Bug: a record field with a list of Secret. It compiles and writes the hidden text.
import Secret

main! = |_args| {
	echo!(Json.to_str({ tokens: [Secret.from_str("hunter2")] }))
	Ok({})
}
