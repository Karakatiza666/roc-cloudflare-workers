## Compiler probe (PLAN.md 8f part 4): does the derived Json parser read a record with optional fields, and does a
## list of records with optional fields type-check?
Match(meta) : { id : Str, score : F64, metadata ?: meta, values ?: List(F64) }
Res(meta) : { matches : List(Match(meta)), count : U64 }

parse_res : Str -> Try(Res(m), [InvalidJson(Str), ..e]) where [m.Json.Parseable([InvalidJson(Str), ..e])]
parse_res = |text| Json.parse(text)

main! = |_args| {
	r : Try(Res({ genre : Str }), _)
	r = parse_res("{\"matches\":[{\"id\":\"a\",\"score\":0.5,\"metadata\":{\"genre\":\"x\"}},{\"id\":\"b\",\"score\":0.1}],\"count\":2}")
	echo!(Str.inspect(r))
	Ok({})
}
