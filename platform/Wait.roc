## The one wait primitive. The host suspends
## the wasm stack with JSPI until JS has the result.
Wait := [].{
	## kind, number, text a, text b, bytes c => status (0: no result), body.
	wait! : U32, U64, Str, Str, List(U8) => { status : U16, body : List(U8) }
}
