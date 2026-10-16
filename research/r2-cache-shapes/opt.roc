Http : { content_type ?: Str, cache_control ?: Str }

with_ct : Http, Str -> Http
with_ct = |h, s| { ..h, content_type: s }

h2 : Http
h2 = with_ct({}, "x")

expect h2.?content_type == Ok("x")
expect h2.?cache_control == Err(MissingField)
