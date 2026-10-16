## Durable Objects (MODULES.md 7). Phase A has the payload types of the event `Object` (API.md 10.1) only.
## Stubs, `class`, `Self` and the storage functions come in phase B (PLAN.md 8f).
import Io
import Js
import Request
import WebSocket

Object :: { namespace : Str, name : Str }.{

	## The events of an object (API.md 10.1).
	Event : [
		Init,
		Fetch(Request),
		Alarm({ retry_count : U32, is_retry : Bool }),
		Rpc({ method : Str, arg : List(U8) }),
		SocketMessage(Object.Socket, WebSocket.Message),
		SocketClose(Object.Socket, WebSocket.Closed),
		SocketError(Object.Socket, Io.Thrown),
	]

	## A WebSocket that the object accepted with the hibernation API (MODULES.md 12.1). It holds a ref (MC13).
	Socket :: { ref : Js.Ref }
}
