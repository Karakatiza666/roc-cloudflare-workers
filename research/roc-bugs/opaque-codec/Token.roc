## The control: the same type with a record backing.
Token :: { text : Str }.{
	from_str : Str -> Token
	from_str = |s| Token.{ text: s }
}
