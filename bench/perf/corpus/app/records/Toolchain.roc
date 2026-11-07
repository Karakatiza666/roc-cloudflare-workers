## The answers of the toolchain routes (Registry R-AP5, R-AP6, R-AP49 row of R-RE4, R-AP73; slice 104e). Pure.
## The encoders write the bytes of `worker/lib/Toolchains.roc` (`row_text`, `put_body`, `page_body`): no white space, a row with the members `tag`, `target`, `asset_name`, `sha256`, `size`, `published_at`, `log_index` in this order (not alphabetical), the rows in the order given.
## The decoders follow R-AP51: all members are required, an unknown member is ignored.
Toolchain :: [].{

	## A row of R-RE4 and R-AP80. `size` is the byte size of the asset (a whole number above 0; the Worker checks it). There is no `url` member: the client builds the URL. `published_at` is milliseconds (R-AP50).
	Row : { tag : Str, target : Str, asset_name : Str, sha256 : Str, size : U64, published_at : U64, log_index : U64 }

	## R-AP5: `{"toolchains":[..],"more":<bool>}`.
	Page : { toolchains : List(Toolchain.Row), more : Bool }

	## R-AP6: `{"toolchains":[..]}`.
	Put : { toolchains : List(Toolchain.Row) }

	list : List(Str) -> Str
	list = |items| "[${Str.join_with(items, ",")}]"

	bad_json : _ -> [BadJson(Str)]
	bad_json = |e| BadJson(Str.inspect(e))

	encode_row : Toolchain.Row -> Str
	encode_row = |r| {
		tag : Str
		tag = Json.to_str(r.tag)
		target : Str
		target = Json.to_str(r.target)
		asset : Str
		asset = Json.to_str(r.asset_name)
		sha : Str
		sha = Json.to_str(r.sha256)
		"{\"tag\":${tag},\"target\":${target},\"asset_name\":${asset},\"sha256\":${sha},\"size\":${r.size.to_str()},\"published_at\":${r.published_at.to_str()},\"log_index\":${r.log_index.to_str()}}"
	}

	decode_row : Str -> Try(Toolchain.Row, [BadJson(Str)])
	decode_row = |text| {
		parsed : Try(Toolchain.Row, _)
		parsed = Json.parse(text)
		parsed.map_err(bad_json)
	}

	encode_page : Toolchain.Page -> Str
	encode_page = |p| "{\"toolchains\":${list(p.toolchains.map(encode_row))},\"more\":${if (p.more) "true" else "false"}}"

	decode_page : Str -> Try(Toolchain.Page, [BadJson(Str)])
	decode_page = |text| {
		parsed : Try(Toolchain.Page, _)
		parsed = Json.parse(text)
		parsed.map_err(bad_json)
	}

	encode_put : Toolchain.Put -> Str
	encode_put = |p| "{\"toolchains\":${list(p.toolchains.map(encode_row))}}"

	decode_put : Str -> Try(Toolchain.Put, [BadJson(Str)])
	decode_put = |text| {
		parsed : Try(Toolchain.Put, _)
		parsed = Json.parse(text)
		parsed.map_err(bad_json)
	}
}
