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

	## `cache.put(url, response)`, then the response to send. A `Stream` body is read by the put, so the program tees it
	## first (`ReadableStream.tee()`): one branch goes to the cache, and the response that `put` gives has the other.
	## Send that response, not the one given. The put reads its branch to the end, so the branch of the response holds the
	## whole body in JS until it is sent: for a large stream use `put_after!`. Other bodies: the same response.
	## A 206 response or a response with `Vary: *` is `CacheErr` (a throw). A response that is not cached
	## (`Set-Cookie`, `no-store`, too large) is `Ok`: `put` does not say it (Cloudflare docs).
	put : Cache, Str, Response -> Io(Response, [CacheErr(Io.Thrown)])
	put = |cache, url, res| {
		init = Record([
			("status", Lit(Int(res.status().to_i64()))),
			("headers", Lit(Arr(res.headers().map(|h| Arr([Text(h.name), Text(h.value)]))))),
		])
		match res.body() {
			Stream(r) => Io.new(
				# Slot 2: [a, b]. Slot 3: a. Slot 4: the init. Slot 5: the put. Slot 6 (the result): b.
				cache_ops(cache).concat([
					Call(Ref(r), "tee", []),
					Get(Slot(2), "0"),
					init,
					New(Root("global"), "Response", [Slot(3), Slot(4)]),
					Call(Slot(1), "put", [Lit(Text(url)), Slot(5)]),
					Get(Slot(2), "1"),
				]),
				|got| match got {
					Ok(Ref(b)) => Ok(res.with_body(Stream(b)))
					Ok(other) => crash "Cache.put: the branch of the tee is ${Str.inspect(other)}"
					Err(t) => Err(CacheErr(t))
				},
			)
			body => {
				arg = match body {
					Text(s) => Text(s)
					Bytes(b) => Bytes(b)
					_ => Null
				}
				Io.new(
					cache_ops(cache).concat([init, New(Root("global"), "Response", [Lit(arg), Slot(2)]), Call(Slot(1), "put", [Lit(Text(url)), Slot(3)])]),
					|got| match got {
						Ok(_) => Ok(res)
						Err(t) => Err(CacheErr(t))
					},
				)
			}
		}
	}

	put! : Cache, Str, Response => Try(Response, [CacheErr(Io.Thrown)])
	put! = |cache, url, res| Io.run!(put(cache, url, res))

	## Put after the response (API.md 10.2): tee a `Stream` body now (one `call!`, no wait), and give the response to
	## send, with `Response.after` work that puts the other branch. The client and the cache read at the same time, so
	## the tee holds only the bytes that one reads before the other. An `Err` of the put is the log line
	## `fetch: after respond: failed: ...`. Only for the response of a `fetch!` handler: elsewhere the work does not run.
	put_after! : Cache, Str, Response => Try(Response, [CacheErr(Io.Thrown)])
	put_after! = |cache, url, res| {
		(mine, theirs) = res.body().tee!() ? |BodyErr(t)| CacheErr(t)
		copy = res.with_body(theirs)
		Ok(res.with_body(mine).after(|| cache.put!(url, copy).map_ok(|_| {})))
	}

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
		Response.from_status(status).with_headers(headers).with_body(body)
	}
	other => crash "Cache: the response is ${Str.inspect(other)}"
}

field : List((Str, Js)), Str -> Js
field = |fields, name| match fields.find_first(|(k, _)| k == name) {
	Ok((_, v)) => v
	Err(_) => Undefined
}
