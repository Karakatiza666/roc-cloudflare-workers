## An opaque type over a bare `Str`, with no `encoder_for` and no `parser_for`.
Secret :: Str.{
	from_str : Str -> Secret
	from_str = |s| Secret.(s)
}
