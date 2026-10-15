## Control: a parse into a tuple with a Secret. Rejected (correct).
import Secret

main! = |_args| {
	parsed : Try((Secret, U64), _)
	parsed = Json.parse("[\"hunter2\",1]")
	echo!(if parsed.is_ok() "parsed" else "failed")
	Ok({})
}
