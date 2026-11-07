## A member that can be `null` on the wire (R-AP51). The derived JSON codec cannot read or write `null`. Private to the package.
Nullable(a) := Try(a, [None]).{

	parser_for : encoding -> (state -> Try({ value : Nullable(a), rest : state }, err))
		where [
			encoding.parse_null : encoding, state -> Try(state, err),
			a.parser_for : encoding -> (state -> Try({ value : a, rest : state }, err)),
		]
	parser_for = |encoding| {
		Encoding : encoding
		Inner : a

		inner = Inner.parser_for(encoding)
		|state| match Encoding.parse_null(encoding, state) {
			Ok(rest) => Ok({ value: Nullable.(Err(None)), rest })
			Err(_) => {
				parsed = inner(state)?
				Ok({ value: Nullable.(Ok(parsed.value)), rest: parsed.rest })
			}
		}
	}

	encoder_for : encoding -> (Nullable(a), state -> Try(state, err))
		where [
			encoding.encode_null : state -> Try(state, err),
			a.encoder_for : encoding -> (a, state -> Try(state, err)),
		]
	encoder_for = |encoding| {
		Encoding : encoding
		Inner : a

		inner = Inner.encoder_for(encoding)
		|Nullable.(value), state| match value {
			Ok(x) => inner(x, state)
			Err(None) => Encoding.encode_null(state)
		}
	}

	## A required member that can be `null`: always written, `null` for none.
	write : Try(a, [None]) -> Nullable(a)
	write = |value| Nullable.(value)

	## The value of a required member.
	read : Nullable(a) -> Try(a, [None])
	read = |Nullable.(value)| value

	## An optional member: left out of the text for none.
	write_opt : Try(a, [None]) -> Try(Nullable(a), [Missing])
	write_opt = |value| value.map_err(|_| Missing).map_ok(|x| Nullable.(Ok(x)))

	## An optional member: a member that is missing or `null` is none.
	read_opt : Try(Nullable(a), [Missing]) -> Try(a, [None])
	read_opt = |member| match member {
		Ok(Nullable.(value)) => value
		Err(Missing) => Err(None)
	}
}
