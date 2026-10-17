## Email (MODULES.md 13). Phase A has the payload type of the event `Email` (API.md 10.1) only.
## The binding, `send!` and the functions of `Mail` (`header`, `forward!`, `reply!`, `set_reject!`) come in phase B.
import Body
import http.Header

Email :: { name : Str }.{

	## An incoming mail. Opaque: phase B gives its functions. `raw_size_bytes` is `rawSize` (MC10).
	Mail :: { from : Str, to : Str, headers : List(Header), raw : Body, raw_size_bytes : U64, can_be_forwarded : Bool }
}
