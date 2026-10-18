## The body of a request or a response (MODULES.md 4): bytes in Roc, or a stream that stays in JS (API.md RS3).
## A stream is a ref of the task (MC13). A read copies bytes into wasm only when Roc asks, to a limit (MC11).
## The JS side of the stream functions is in `js/helpers.js` (the root `pf`).
import Js
import Io

Body := [Empty, Text(Str), Bytes(List(U8)), Stream(Js.Ref)].{

	## The default limit of a read into wasm memory: 1 MiB (MC11).
	default_max : U64
	default_max = 1_048_576

	## The formats of `compress!` and `decompress!`.
	Format : [Gzip, Deflate]

	## The body as UTF-8 text, to `default_max` bytes.
	text! : Body => Try(Str, [TooLarge, BadData(Str), BodyErr(Io.Thrown)])
	text! = |body| match body {
		Text(s) => if s.count_utf8_bytes() > default_max Err(TooLarge) else Ok(s)
		_ => {
			bytes = match bytes_with!(body, { max_bytes: default_max }) {
				Ok(b) => b
				Err(TooLarge) => return Err(TooLarge)
				Err(BodyErr(t)) => return Err(BodyErr(t))
			}
			Str.from_utf8(bytes).map_err(|_| BadData("the body is not UTF-8"))
		}
	}

	## The body as JSON, to `default_max` bytes. A parse error is `BadData` (MODULES.md 15).
	json! : Body => Try(a, [TooLarge, BadData(Str), BodyErr(Io.Thrown)]) where [a.Json.Parseable([InvalidJson(Str), ..errs])]
	json! = |body| {
		text = text!(body)?
		Json.parse(text).map_err(|e| BadData(Str.inspect(e)))
	}

	## The bytes of the body, to `default_max` bytes.
	bytes! : Body => Try(List(U8), [TooLarge, BodyErr(Io.Thrown)])
	bytes! = |body| bytes_with!(body, { max_bytes: default_max })

	## The bytes of the body, to `max_bytes`. More is `TooLarge`. A stream: one wait, and JS checks the size
	## before the copy into wasm (`pf.readUpTo`), so a body over the limit takes no wasm memory.
	bytes_with! : Body, { max_bytes : U64 } => Try(List(U8), [TooLarge, BodyErr(Io.Thrown)])
	bytes_with! = |body, { max_bytes }| {
		bytes = match body {
			Empty => []
			Text(s) => s.to_utf8()
			Bytes(b) => b
			Stream(r) => match Js.await!([Call(Root("pf"), "readUpTo", [Lit(Ref(r)), Lit(Int(limit(max_bytes)))])]) {
				Ok(Bytes(b)) => b
				Ok(other) => crash "Body.bytes_with!: readUpTo gave ${Str.inspect(other)}"
				Err(t) if t.name == "TooLarge" => return Err(TooLarge)
				Err(t) => return Err(BodyErr(t))
			}
		}
		if bytes.len() > max_bytes Err(TooLarge) else Ok(bytes)
	}

	## The next chunk of a stream, as JS gives it, cut to `default_max` (MC11). One wait.
	## `Empty`, `Text` and `Bytes` are one chunk (none for `Empty`), with no crossing: a value is not a stream, so
	## each call on the same value gives the same chunk.
	chunk! : Body => Try([Chunk(List(U8)), End], [BodyErr(Io.Thrown)])
	chunk! = |body| match body {
		Empty => Ok(End)
		Text(s) => Ok(Chunk(s.to_utf8()))
		Bytes(b) => Ok(Chunk(b))
		Stream(r) => match Js.await!([Call(Root("pf"), "chunk", [Lit(Ref(r)), Lit(Int(limit(default_max)))])]) {
			Ok(Bytes(b)) => Ok(Chunk(b))
			Ok(Undefined) => Ok(End)
			Ok(other) => crash "Body.chunk!: pf.chunk gave ${Str.inspect(other)}"
			Err(t) => Err(BodyErr(t))
		}
	}

	## Two bodies with the same bytes. A stream: `ReadableStream.tee()`, no wait. A stream that was read is `BodyErr`.
	tee! : Body => Try((Body, Body), [BodyErr(Io.Thrown)])
	tee! = |body| match body {
		Stream(r) => match Js.call!([Call(Ref(r), "tee", [])]) {
			Ok(Arr([Ref(a), Ref(b)])) => Ok((Stream(a), Stream(b)))
			Ok(other) => crash "Body.tee!: tee gave ${Str.inspect(other)}"
			Err(t) => Err(BodyErr(t))
		}
		_ => Ok((body, body))
	}

	## The SHA-256 of the body (32 bytes). A stream: `crypto.DigestStream` in JS, one wait, no copy into wasm.
	## `Text` and `Bytes`: the builtin `Crypto.SHA256` in wasm, no crossing.
	sha256! : Body => Try(List(U8), [BodyErr(Io.Thrown)])
	sha256! = |body| match body {
		Empty => Ok(Crypto.SHA256.hash([]).to_bytes())
		Text(s) => Ok(Crypto.SHA256.hash(s.to_utf8()).to_bytes())
		Bytes(b) => Ok(Crypto.SHA256.hash(b).to_bytes())
		Stream(r) => match Js.await!([Call(Root("pf"), "sha256", [Lit(Ref(r))])]) {
			Ok(Bytes(d)) => Ok(d)
			Ok(other) => crash "Body.sha256!: pf.sha256 gave ${Str.inspect(other)}"
			Err(t) => Err(BodyErr(t))
		}
	}

	## A stream that the task writes, for example in the work of `Response.after` (API.md 10.2): `pf.writer`, a
	## `TransformStream`, no wait. The 30 s limit after the response starts at `close!`.
	writer! : () => Try({ body : Body, writer : Body.Writer }, [BodyErr(Io.Thrown)])
	writer! = || match Js.call!([Call(Root("pf"), "writer", [])]) {
		Ok(Obj(fields)) => match (field(fields, "readable"), field(fields, "writer")) {
			(Ref(readable), Ref(w)) => Ok({ body: Stream(readable), writer: Body.Writer.{ writer: w } })
			_ => crash "Body.writer!: pf.writer gave ${Str.inspect(Obj(fields))}"
		}
		Ok(other) => crash "Body.writer!: pf.writer gave ${Str.inspect(other)}"
		Err(t) => Err(BodyErr(t))
	}

	## `pipeThrough(new CompressionStream(format))`, no wait. A `Text` or `Bytes` body becomes a stream first.
	## The result is a `Stream`: the bytes stay in JS.
	compress! : Body, Body.Format => Try(Body, [BodyErr(Io.Thrown)])
	compress! = |body, format| transform!(body, "compress", format)

	## `pipeThrough(new DecompressionStream(format))`, no wait. As `compress!`.
	decompress! : Body, Body.Format => Try(Body, [BodyErr(Io.Thrown)])
	decompress! = |body, format| transform!(body, "decompress", format)

	## The writable side of a `writer!` stream. It holds a ref, so it is good for one task (MC13).
	Writer :: { writer : Js.Ref }.{

		## One wait: until the stream takes the chunk (the reader asked for it, MC3). After `close!`: `BodyErr`.
		## The twin gives an `Io`, so a write can run next to the read of the stream (`Io.race!`, `Io.start!`).
		write : Body.Writer, List(U8) -> Io({}, [BodyErr(Io.Thrown)])
		write = |w, bytes| {
			Body.Writer.{ writer } = w
			Io.new(
				[Call(Ref(writer), "write", [Lit(Bytes(bytes))])],
				|r| match r {
					Ok(_) => Ok({})
					Err(t) => Err(BodyErr(t))
				},
			)
		}

		write! : Body.Writer, List(U8) => Try({}, [BodyErr(Io.Thrown)])
		write! = |w, bytes| Io.run!(write(w, bytes))

		## The text as UTF-8 (a stream of a response takes bytes only).
		write_text : Body.Writer, Str -> Io({}, [BodyErr(Io.Thrown)])
		write_text = |w, text| write(w, text.to_utf8())

		write_text! : Body.Writer, Str => Try({}, [BodyErr(Io.Thrown)])
		write_text! = |w, text| Io.run!(write_text(w, text))

		## No wait. The body is complete now (API.md 10.2): the 30 s limit after `respond!` starts.
		close! : Body.Writer => {}
		close! = |w| {
			Body.Writer.{ writer } = w
			_ = Js.call!([Call(Root("pf"), "close", [Lit(Ref(writer))])])
			{}
		}
	}
}

## `pf.transform(body, kind, format)`: a stream through a `CompressionStream` or a `DecompressionStream`.
transform! : Body, Str, Body.Format => Try(Body, [BodyErr(Io.Thrown)])
transform! = |body, kind, format| {
	name = match format {
		Gzip => "gzip"
		Deflate => "deflate"
	}
	input = match body {
		Empty => Null
		Text(s) => Text(s)
		Bytes(b) => Bytes(b)
		Stream(r) => Ref(r)
	}
	match Js.call!([Call(Root("pf"), "transform", [Lit(input), Lit(Text(kind)), Lit(Text(name))])]) {
		Ok(Ref(r)) => Ok(Stream(r))
		Ok(other) => crash "Body.${kind}!: pf.transform gave ${Str.inspect(other)}"
		Err(t) => Err(BodyErr(t))
	}
}

## A limit as the `Int` of a program (I64). Above the range of I64: the highest I64, which no body reaches.
limit : U64 -> I64
limit = |n| n.to_i64_try() ?? I64.highest

field : List((Str, Js)), Str -> Js
field = |fields, name| match fields.find_first(|(k, _)| k == name) {
	Ok((_, v)) => v
	Err(_) => Undefined
}
