import Io
import Body

## An R2 bucket. Bodies stay streams in JS (API.md RS3).
R2 :: { name : Str }.{
	binding : Str -> R2
	binding = |name| R2.{ name }

	## `put` with options. `only_if` makes it a compare and swap: a failed condition is `PreconditionFailed`.
	put_with : R2, Str, Body, { only_if ?: R2.Cond, http ?: R2.Http, custom ?: List((Str, Str)), checksum ?: R2.Checksum, length_bytes ?: U64 } -> Io(R2.Meta, [PreconditionFailed, R2Err(Io.Thrown)])
	put_with = |bucket, key, _body, opts| {
		R2.{ name } = bucket
		cond = match opts.?only_if {
			Ok(c) => cond_text(c)
			Err(MissingField) => "none"
		}
		content_type = opts.?http.map_ok(|h| h.?content_type ?? "") ?? ""
		length = opts.?length_bytes.map_ok(|n| n.to_str()) ?? "unknown"
		Io.new(["r2.put", name, key, cond, content_type, length], |r| match r {
			Ok(bytes) if bytes == Io.null => Err(PreconditionFailed)
			Ok(bytes) => Io.decode(bytes).map_err(|BadData(m)| R2Err({ name: "BadData", message: m }))
			Err(t) => Err(R2Err(t))
		})
	}

	put_with! : R2, Str, Body, { only_if ?: R2.Cond, http ?: R2.Http, custom ?: List((Str, Str)), checksum ?: R2.Checksum, length_bytes ?: U64 } => Try(R2.Meta, [PreconditionFailed, R2Err(Io.Thrown)])
	put_with! = |bucket, key, body, opts| Io.run!(put_with(bucket, key, body, opts))

	## `R2Conditional`: R2 checks each field that is there.
	Cond : { etag_matches ?: Str, etag_does_not_match ?: Str, uploaded_before_ms ?: U64, uploaded_after_ms ?: U64 }

	## Only a new key (`etagDoesNotMatch: "*"`).
	absent : R2.Cond
	absent = { etag_does_not_match: "*" }

	Meta : { key : Str, version : Str, size_bytes : U64, etag : Str, http_etag : Str, uploaded_ms : U64, http : R2.Http, custom : List((Str, Str)), checksums : R2.Checksums }

	Http : { content_type ?: Str, content_language ?: Str, content_disposition ?: Str, content_encoding ?: Str, cache_control ?: Str, cache_expiry_ms ?: U64 }

	Checksums : { md5 ?: List(U8), sha1 ?: List(U8), sha256 ?: List(U8), sha384 ?: List(U8), sha512 ?: List(U8) }

	Checksum : [Md5(List(U8)), Sha1(List(U8)), Sha256(List(U8)), Sha384(List(U8)), Sha512(List(U8))]
}

## The condition as the fake JS side reads it: one part for each field that is there.
cond_text : R2.Cond -> Str
cond_text = |c| {
	parts = [
		c.?etag_matches.map_ok(|e| "match:${e}"),
		c.?etag_does_not_match.map_ok(|e| "none-match:${e}"),
		c.?uploaded_before_ms.map_ok(|t| "before:${t.to_str()}"),
		c.?uploaded_after_ms.map_ok(|t| "after:${t.to_str()}"),
	]
	Str.join_with(parts.keep_oks(|p| p), ",")
}
