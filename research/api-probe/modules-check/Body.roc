## A body: bytes in Roc, or a stream that stays in JS (API.md RS3).
Body := [Empty, Text(Str), Bytes(List(U8)), Stream(U32)].{
	## The default limit of a read into wasm memory (MODULES.md MC6).
	default_max : U64
	default_max = 1_048_576

	text! : Body => Try(Str, [TooLarge, BadData(Str)])
	text! = |b| match b {
		Empty => Ok("")
		Text(s) => if s.count_utf8_bytes() > default_max Err(TooLarge) else Ok(s)
		Bytes(bytes) => Str.from_utf8(bytes).map_err(|_| BadData("not UTF-8"))
		Stream(_) => Ok("streamed")
	}

	json! : Body => Try(a, [TooLarge, BadData(Str)]) where [a.Json.Parseable([InvalidJson(Str), ..errs])]
	json! = |b| match b.text!() {
		Ok(text) => Json.parse(text).map_err(|e| BadData(Str.inspect(e)))
		Err(TooLarge) => Err(TooLarge)
		Err(BadData(m)) => Err(BadData(m))
	}
}
