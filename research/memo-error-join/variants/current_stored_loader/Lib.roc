## The current Memo shape: the constant stores `load!`, so its type has the error parameter.
Lib := [].{
	Memo(a, e) := { name : Str, max_age_ms : U64, load! : () => Try(a, e) }.{
		get! : Lib.Memo(a, e) => Try(a, e)
		get! = |m| {
			load! = m.load!
			load!()
		}
	}

	create_tables! : () => Try({}, [Constraint(Str), Infra([D1Err(Str)])])
	create_tables! = || Err(Infra(D1Err("x")))

	tables : Lib.Memo({}, _)
	tables = { name: "tables", max_age_ms: 60_000, load!: Lib.create_tables! }

	kv_get! : () => Try(Str, [Infra([KvErr(Str), TooLarge])])
	kv_get! = || Ok("v")
}
