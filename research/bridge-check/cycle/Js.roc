## `Js.await!` (API.md 6.4) would call `Host.await!`, so `Js` imports `Host`: a cycle.
import Host

Js := [Undefined, Text(Str)].{
	await! : Js => Js
	await! = |prog| Host.await!(prog).value
}
