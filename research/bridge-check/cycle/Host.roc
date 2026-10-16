## The hosted function takes a `Js`, so `Host` imports `Js`.
import Js

Host :: [].{
	await! : Js => { status : U8, value : Js }
}
