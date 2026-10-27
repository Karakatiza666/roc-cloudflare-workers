import Lib

# Two callers with other Infra payloads, one inferred, one annotated.
web! = || {
	Lib.tables.get!()?
	v = Lib.kv_get!()?
	Ok(v)
}

ledger! : () => Try(Str, [Constraint(Str), Infra([D1Err(Str), RpcErr(Str), KvErr(Str), TooLarge])])
ledger! = || {
	Lib.tables.get!()?
	v = Lib.kv_get!()?
	Ok(v)
}

main! = |_args| {
	echo!(Str.inspect(web!()))
	echo!(Str.inspect(ledger!()))
	Ok({})
}
