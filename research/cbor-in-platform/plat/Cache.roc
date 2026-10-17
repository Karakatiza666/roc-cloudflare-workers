## The Cache API (MODULES.md 5.4): `caches.default` or `caches.open(name)`, then one call, in one program. The key is
## a URL: a string is a `GET` request for it, so `match` and `delete` need no `ignoreMethod`. One data center (RF1).
import Io
import Js
import Response
import Body
import http.Header

Cache :: { which : [Default, Named(Str)] }.{

	## `caches.default`.
	default : Cache
	default = Cache.{ which: Default }

	## `caches.open(name)`, in the program of each call: it gives data (MC1), not a promise.
	named : Str -> Cache
	named = |name| Cache.{ which: Named(name) }

	## `cache.match(url)`. The body is a stream (`Http.open!`): `res.text!()` is one more wait. A key that is not
	## cached: `NotFound` (OP7: `Fields` of the `undefined` result).
	get : Cache, Str -> Io(Response, [NotFound, CacheErr(Io.Thrown)])
	get = |cache, url| Io.new(
		cache_ops(cache).concat([
			Call(Slot(1), "match", [Lit(Text(url))]),
			Fields(Slot(2), ["status", "headers", "body"]),
		]),
		|r| match r {
			Ok(v) => match v {
				Undefined | Null => Err(NotFound)
				_ => Ok(response_of(v))
			}
			Err(t) => Err(CacheErr(t))
		},
	)

	get! : Cache, Str => Try(Response, [NotFound, CacheErr(Io.Thrown)])
	get! = |cache, url| Io.run!(get(cache, url))

	## `cache.put(url, response)`. A 206 response or a response with `Vary: *` is `CacheErr` (a throw). A response
	## that is not cached (`Set-Cookie`, `no-store`, too large) is `Ok`: `put` does not say it (Cloudflare docs).
	## A `Stream` body is read by the put.
	put : Cache, Str, Response -> Io({}, [CacheErr(Io.Thrown)])
	put = |cache, url, res| {
		body = match res.body {
			Empty => Null
			Text(s) => Text(s)
			Bytes(b) => Bytes(b)
			Stream(r) => Ref(r)
		}
		init = [
			("status", Lit(Int(res.status.to_i64()))),
			("headers", Lit(Arr(res.headers.map(|h| Arr([Text(h.name), Text(h.value)]))))),
		]
		Io.new(
			cache_ops(cache).concat([
				Record(init),
				New(Root("global"), "Response", [Lit(body), Slot(2)]),
				Call(Slot(1), "put", [Lit(Text(url)), Slot(3)]),
			]),
			|r| match r {
				Ok(_) => Ok({})
				Err(t) => Err(CacheErr(t))
			},
		)
	}

	put! : Cache, Str, Response => Try({}, [CacheErr(Io.Thrown)])
	put! = |cache, url, res| Io.run!(put(cache, url, res))

	## `cache.delete(url)`: `false` is `NotFound`.
	delete : Cache, Str -> Io({}, [NotFound, CacheErr(Io.Thrown)])
	delete = |cache, url| Io.new(
		cache_ops(cache).append(Call(Slot(1), "delete", [Lit(Text(url))])),
		|r| match r {
			Ok(Bool(Bool.True)) => Ok({})
			Ok(Bool(Bool.False)) => Err(NotFound)
			Ok(other) => crash "Cache.delete: delete gave ${Str.inspect(other)}"
			Err(t) => Err(CacheErr(t))
		},
	)

	delete! : Cache, Str => Try({}, [NotFound, CacheErr(Io.Thrown)])
	delete! = |cache, url| Io.run!(delete(cache, url))
}

## Slot 0: `caches`. Slot 1: the cache (`default` is a property, `open` gives a promise).
cache_ops : Cache -> List(Js.Op)
cache_ops = |cache| match cache.which {
	Default => [Get(Root("global"), "caches"), Get(Slot(0), "default")]
	Named(name) => [Get(Root("global"), "caches"), Call(Slot(0), "open", [Lit(Text(name))])]
}

## The record of `Fields`, as in `Http`.
response_of : Js -> Response
response_of = |v| match v {
	Obj(fields) => {
		status = match field(fields, "status") {
			Int(i) => i.to_u16_try() ?? crash "Cache: the status ${i.to_str()} is out of range"
			other => crash "Cache: the status is ${Str.inspect(other)}"
		}
		headers = match field(fields, "headers") {
			Arr(items) => items.map(
				|h| match h {
					Arr([Text(name), Text(value)]) => Header.{ name, value }
					other => crash "Cache: a header is ${Str.inspect(other)}"
				},
			)
			other => crash "Cache: the headers are ${Str.inspect(other)}"
		}
		body = match field(fields, "body") {
			Undefined | Null => Empty
			Ref(r) => Stream(r)
			other => crash "Cache: the body is ${Str.inspect(other)}"
		}
		Response.{ status, headers, body }
	}
	other => crash "Cache: the response is ${Str.inspect(other)}"
}

field : List((Str, Js)), Str -> Js
field = |fields, name| match fields.find_first(|(k, _)| k == name) {
	Ok((_, v)) => v
	Err(_) => Undefined
}
