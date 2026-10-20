Req := { body : Str }.{
	new : Str -> Req
	new = |s| { body: s }
}
