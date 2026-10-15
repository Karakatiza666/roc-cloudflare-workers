## Control: a record field of an opaque type with a record backing. Rejected (correct).
import Token

main! = |_args| {
	echo!(Json.to_str({ token: Token.from_str("hunter2") }))
	Ok({})
}
