import Io
import Body
import Request
import Response

## Outgoing HTTP: `fetch`, with the body read in the same crossing (to `Body.default_max`).
Http :: [].{
	send : Request -> Io(Response, [Network(Io.Thrown), HttpErr(Io.Thrown), TooLarge])
	send = |req| Io.tree(["http.send", req.url, Io.max(Body.default_max)], |t| throw(t)).map(|r| Response.from_status(r.status).with_body(r.body))

	send! : Request => Try(Response, [Network(Io.Thrown), HttpErr(Io.Thrown), TooLarge])
	send! = |req| Io.run!(send(req))

	get : Str -> Io(Response, [Network(Io.Thrown), HttpErr(Io.Thrown), TooLarge])
	get = |url| send(Request.get(url))

	get! : Str => Try(Response, [Network(Io.Thrown), HttpErr(Io.Thrown), TooLarge])
	get! = |url| Io.run!(get(url))
}

## MC9, table "Named error tags": a `TypeError` is a bad request, each other throw is no response.
throw : Io.Thrown -> [Network(Io.Thrown), HttpErr(Io.Thrown), TooLarge]
throw = |t|
	if Io.too_large(t) {
		TooLarge
	} else if t.name == "TypeError" {
		HttpErr(t)
	} else {
		Network(t)
	}
