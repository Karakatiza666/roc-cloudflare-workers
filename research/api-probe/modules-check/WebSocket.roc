import Io
import Request
import Response

## A WebSocket in a Worker, or a client (MODULES.md 12.2). A value holds a ref, so it is good
## for one task (MC13). The fake JS side has no messages: `receive!` gives `Closed`.
WebSocket :: { ref : U32 }.{
	is_eq : _

	is_upgrade : Request -> Bool
	is_upgrade = |req| (req.header("upgrade") ?? "").with_ascii_lowercased() == "websocket"

	accept! : Request => Try({ socket : WebSocket, response : Response }, [NotUpgrade])
	accept! = |req|
		if WebSocket.is_upgrade(req) {
			ref : Try(U32, _)
			ref = Io.run!(Io.typed(["ws.accept"], |_| BadData("")))
			r = ref ?? 0
			Ok({ socket: WebSocket.{ ref: r }, response: Response.{ status: 101, headers: [], body: Empty, web_socket: r + 1 } })
		} else {
			Err(NotUpgrade)
		}

	send! : WebSocket, WebSocket.Message => Try({}, [Closed])
	send! = |_, _| Ok({})

	receive! : WebSocket => Try(WebSocket.Message, [Closed(WebSocket.Closed)])
	receive! = |_| Err(Closed({ code: 1000, reason: "", clean: Bool.True }))

	close! : WebSocket, U16, Str => {}
	close! = |_, _, _| {}

	## A frame. `json` parses a text frame.
	Message := [Text(Str), Bytes(List(U8))].{
		json : WebSocket.Message -> Try(a, [BadData(Str)]) where [a.Json.Parseable([InvalidJson(Str), ..errs])]
		json = |m| match m {
			Text(t) => Json.parse(t).map_err(|e| BadData(Str.inspect(e)))
			Bytes(_) => Err(BadData("a bytes frame"))
		}
	}

	Closed : { code : U16, reason : Str, clean : Bool }
}
