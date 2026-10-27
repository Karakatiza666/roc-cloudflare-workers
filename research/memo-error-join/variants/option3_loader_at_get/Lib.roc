## Option 3 prototype: the constant has no error parameter; `get!` takes the loader.
Lib := [].{
	Memo(a) := { name : Str, max_age_ms : U64, seed : a }.{
		get! : Lib.Memo(a), (() => Try(a, e)) => Try(a, e)
		get! = |_m, load!| load!()
	}

	tables : Lib.Memo({})
	tables = { name: "tables", max_age_ms: 60_000, seed: {} }

	create_tables! : () => Try({}, [Constraint(Str), Infra([D1Err(Str)])])
	create_tables! = || Err(Infra(D1Err("x")))

	kv_get! : () => Try(Str, [Infra([KvErr(Str), TooLarge])])
	kv_get! = || Ok("v")
}
