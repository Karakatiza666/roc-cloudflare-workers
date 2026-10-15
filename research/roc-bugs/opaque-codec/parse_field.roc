## Control: a parse into a record field of the type Secret. Rejected (correct).
import Secret

main! = |_args| {
	parsed : Try({ token : Secret }, _)
	parsed = Json.parse("{\"token\":\"hunter2\"}")
	echo!(Str.inspect(parsed))
	Ok({})
}
