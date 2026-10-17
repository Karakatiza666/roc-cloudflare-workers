## The hosted functions (API.md 4). Not in `exposes`: apps reach them through `Io` and `Native`.
import Js

Host :: [].{
	## Run a program with one JSPI wait. Status 0 to 3 (API.md 4).
	await! : Js => { status : U8, value : Js }

	## Run a program with no wait. A promise is status 2.
	call! : Js => { status : U8, value : Js }

	## A native op of the host (API.md 8, PLAN.md 8e). Apps use `Native`.
	native! : U32, List(U8) => { status : U8, bytes : List(U8) }
}
