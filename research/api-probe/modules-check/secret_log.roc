## Must not compile: a log line with a secret in its fields (MODULES.md 10).
import Secret

main! = |_args| {
	echo!(Json.to_str({ token: Secret.from_str("hunter2"), n: 1.U64 }))
	Ok({})
}
