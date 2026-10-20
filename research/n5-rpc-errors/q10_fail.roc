## Q10 (fails on purpose), option G: a row inside the payload, `[Infra([TimedOut, ..i]), ..e]`, in a generic
## combinator. Both forms give `type mismatch`. q10_row_infra.roc has the form that compiles.
Thrown : { name : Str, message : Str }

## (1) `?` on the result of a call.
timeout1 : (() -> Try(a, [Infra([..i]), ..e])), Bool -> Try(a, [Infra([TimedOut, ..i]), ..e])
timeout1 = |run, late| {
	if late {
		return Err(Infra(TimedOut))
	}
	v = run()?
	Ok(v)
}

## (2) A match on the parameter.
timeout2 : Try(a, [Infra([..i]), ..e]), Bool -> Try(a, [Infra([TimedOut, ..i]), ..e])
timeout2 = |r, late| if (late) Err(Infra(TimedOut)) else match r {
	Ok(v) => Ok(v)
	Err(Infra(x)) => Err(Infra(x))
	Err(other) => Err(other)
}

main! = |_args| {
	echo!(Str.inspect(timeout1(|| Ok(1), Bool.True)))
	echo!(Str.inspect(timeout2(Ok(1), Bool.True)))
	Ok({})
}
