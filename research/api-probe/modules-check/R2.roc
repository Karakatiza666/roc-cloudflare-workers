import Io
import Body

## An R2 bucket. Bodies stay streams in JS (API.md RS3).
R2 :: { name : Str }.{
	binding : Str -> R2
	binding = |name| R2.{ name }

	## `put` with options. `only_if` makes it a compare and swap: a failed condition is `PreconditionFailed`.
	put_with : R2, Str, Body, { only_if ?: R2.Cond, content_type ?: Str } -> Io(R2.Meta, [PreconditionFailed, R2Err(Io.Thrown), BadData(Str)])
	put_with = |bucket, key, _body, opts| {
		R2.{ name } = bucket
		cond = match opts.?only_if {
			Ok(EtagIs(e)) => e
			Ok(Absent) => "absent"
			Err(MissingField) => "none"
		}
		Io.new(["r2.put", name, key, cond], |r| match r {
			Ok(bytes) if bytes == Io.null => Err(PreconditionFailed)
			Ok(bytes) => Io.decode(bytes)
			Err(t) => Err(R2Err(t))
		})
	}

	put_with! : R2, Str, Body, { only_if ?: R2.Cond, content_type ?: Str } => Try(R2.Meta, [PreconditionFailed, R2Err(Io.Thrown), BadData(Str)])
	put_with! = |bucket, key, body, opts| Io.run!(put_with(bucket, key, body, opts))

	Cond : [EtagIs(Str), Absent]

	Meta : { etag : Str, size : U64 }
}
