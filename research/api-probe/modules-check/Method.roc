## A copy of `Method` of `roc-lang/http` 2.0.0: a nominal tag union.
Method := [OPTIONS, GET, POST, PUT, DELETE, HEAD, TRACE, CONNECT, PATCH, QUERY, Unknown(Str)].{
	to_str : Method -> Str
	to_str = |m| match m {
		GET => "GET"
		POST => "POST"
		_ => "OTHER"
	}
}
