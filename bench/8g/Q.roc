## Helpers of the routes: query parameters.
import pf.Request

Q :: [].{

	## A query parameter as text, or "".
	text : Request, Str -> Str
	text = |req, name| req.query(name) ?? ""

	## A query parameter as a number, or 0.
	num : Request, Str -> U64
	num = |req, name| U64.from_str(req.query(name) ?? "0") ?? 0
}
