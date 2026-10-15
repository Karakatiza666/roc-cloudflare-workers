## The smallest format: it reads one U64 from the first byte.
Tiny := [Tiny].{
	a.Parseable(errs) :
		where [
			a.parser_for : Tiny -> (List(U8) -> Try({ value : a, rest : List(U8) }, errs)),
		]

	parse_u64 : Tiny, List(U8) -> Try({ value : U64, rest : List(U8) }, [Empty])
	parse_u64 = |_, bytes| match bytes {
		[b, .. as rest] => Ok({ value: b.to_u64(), rest })
		[] => Err(Empty)
	}
}
