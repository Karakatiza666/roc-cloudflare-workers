## A secret. `Str.inspect` shows `Secret(...)`. A JSON encode of a value with a secret in it,
## as in `Log`, is a compile error (`secret_log.roc`). The backing must be a record: an
## opaque type over a bare `Str` gets the JSON codec of `Str` (nightlies 10-09 and 10-12).
Secret :: { text : Str }.{
	from_str : Str -> Secret
	from_str = |s| Secret.{ text: s }

	reveal : Secret -> Str
	reveal = |s| s.text

	to_inspect : Secret -> Str
	to_inspect = |_| "Secret(...)"
}
