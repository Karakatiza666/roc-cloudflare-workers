import Io
import Body
import Request
import Response

## Outgoing HTTP: `fetch`, with the body read in the same crossing (to `Body.default_max`).
Http :: [].{
	send : Request -> Io(Response, [HttpErr(Io.Thrown), BadData(Str)])
	send = |req| Io.typed(["http.send", req.url], |t| HttpErr(t)).map(|r| Response.from_status(r.status).with_body(r.body))

	send! : Request => Try(Response, [HttpErr(Io.Thrown), BadData(Str)])
	send! = |req| Io.run!(send(req))
}
