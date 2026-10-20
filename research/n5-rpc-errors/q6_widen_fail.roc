## Q6 (fails on purpose): a value of a closed union is not a value of a larger closed union with no match.
Infra : [StorageErr(Str), TooLarge]

Fault(err) : [Fail(err), StorageErr(Str), TooLarge]

widen : Infra -> Fault(err)
widen = |i| i

main! = |_args| {
	x : Fault([NotOpen])
	x = widen(TooLarge)
	echo!(Str.inspect(x))
	Ok({})
}
