platform ""
	requires { main! : Js => Js }
	exposes [Js]
	packages {}
	provides { "roc_main": main_for_host! }
	hosted { "roc_decode": Host.decode! }
	targets: {
		inputs_dir: "targets/",
		wasm32: { inputs: ["host.wasm", app], output: Shared, exports: [] },
	}

import Js
import Host

main_for_host! : Js => Js
main_for_host! = |v| main!(v)
