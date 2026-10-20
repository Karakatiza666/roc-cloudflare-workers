## Plain app, no platform: parse a generic nominal tag union with a `{}` payload.
Reply(ret, err) := [Ok(ret), Err(err)].{
	parser_for : _
	encoder_for : _
}

reply_of : Str -> Try(ret, [BadData(Str), Remote(err)]) where [ret.Encoding.Json.Parseable(e1), err.Encoding.Json.Parseable(e2)]
reply_of = |text| {
	r : Try(Reply(ret, err), _)
	r = Json.parse(text)
	match r {
		Ok(Reply.Ok(v)) => Ok(v)
		Ok(Reply.Err(e)) => Err(Remote(e))
		Err(e) => Err(BadData(Str.inspect(e)))
	}
}

call : Str -> Try(Str, [BadData(Str), Remote([AlreadyOpen])])
call = |t| reply_of(t)

main! = |_args| {
	match call("{\"Ok\":\"x\"}") {
		Ok(s) => echo!("ok ${s}\n")
		Err(e) => echo!("err ${Str.inspect(e)}\n")
	}
	Ok({})
}
