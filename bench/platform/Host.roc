## The native hosted function (API.md 8). Not in `exposes`: apps use `Native`. The two program runs are in `Js`
## (`Js.host_await!`, `Js.host_call!`), because their type is `Js`.
Host :: [].{

	## A native op of the host (API.md 8, PLAN.md 8e). Apps use `Native`.
	native! : U32, List(U8) => { status : U8, bytes : List(U8) }
}
