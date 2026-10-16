## WebSockets (MODULES.md 12). Phase A has the payload types of the object events (API.md 10.1) only.
## `accept!`, `connect!`, `send!`, `receive!` and `close!` come in phase B (PLAN.md 8f).
import Js

WebSocket :: { ref : Js.Ref }.{

	## One frame.
	Message := [Text(Str), Bytes(List(U8))]

	## The close of a socket.
	Closed : { code : U16, reason : Str, clean : Bool }
}
