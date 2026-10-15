## Control for bool_field.roc: a plain Bool in a record, with no W. It must print {"v":true}.
main! = |_args| {
	echo!(Json.to_str({ v: Bool.True }))
	Ok({})
}
