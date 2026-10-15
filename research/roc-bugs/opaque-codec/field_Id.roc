## Bug: a record field of the type Id (opaque over U32). It compiles and writes the number.
import Id

main! = |_args| {
	echo!(Json.to_str({ id: Id.from_u32(7) }))
	Ok({})
}
