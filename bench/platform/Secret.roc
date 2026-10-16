## A secret (MODULES.md 10). `Str.inspect` shows `Secret(...)`, and only `reveal` gives the text. It has no codec, so a
## `Log` line or typed data (CBOR) with a secret in it does not compile (`conformance/must-not-compile/`).
## The backing is a record: an opaque type over a bare `Str` gets the codecs of `Str` (roc-lang/roc#12309, MODULES.md 15).
Secret :: { text : Str }.{

	## `Env.secret!` makes one. An app can make one for a text that it must not log (a token from a response).
	from_str : Str -> Secret
	from_str = |text| Secret.{ text }

	reveal : Secret -> Str
	reveal = |s| s.text

	to_inspect : Secret -> Str
	to_inspect = |_| "Secret(...)"
}

expect Str.inspect(Secret.from_str("hunter2")) == "Secret(...)"
expect Secret.from_str("hunter2").reveal() == "hunter2"
