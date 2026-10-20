platform ""
	requires {} { handle! : Req => Str }
	exposes [Req]
	packages {}
	provides { "roc_handle": handle_for_host! }

import Req

handle_for_host! : Str => Str
handle_for_host! = |s| handle!(Req.new(s))
