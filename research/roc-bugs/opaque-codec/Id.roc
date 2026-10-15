## An opaque type over a bare `U32`, with no `encoder_for` and no `parser_for`.
Id :: U32.{
	from_u32 : U32 -> Id
	from_u32 = |n| Id.(n)
}
