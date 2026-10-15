## Bug: a record field of the type Secret. It compiles and writes the hidden text.
import Secret

main! = |_args| {
	echo!(Json.to_str({ token: Secret.from_str("hunter2") }))
	Ok({})
}
