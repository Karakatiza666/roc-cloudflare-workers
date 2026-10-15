## Bug: a tuple with a Secret. It compiles and writes the hidden text.
import Secret

main! = |_args| {
	echo!(Json.to_str((Secret.from_str("hunter2"), 1.U64)))
	Ok({})
}
