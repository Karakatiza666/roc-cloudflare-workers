app [handle!] { pf: platform "plat/main.roc" }

import pf.Req

handle! : Req => Str
handle! = |req| req.body
