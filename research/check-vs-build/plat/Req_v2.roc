Req :: { body : Str }.{
	new : Str -> Req
	new = |s| { body: s }

	body : Req -> Str
	body = |r| r.body
}
