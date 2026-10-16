platform ""
	requires {} { handle! : Str => Str }
	exposes [Js]
	packages {}
	provides { "roc_handle": handle_for_host! }
	hosted { "roc_await": Host.await! }
	targets: {
		inputs_dir: "targets/",
		wasm32: {
			inputs: ["host.wasm", app],
			output: Shared,
		},
	}

import Js
import Host

handle_for_host! : Str => Str
handle_for_host! = |req| handle!(req)
