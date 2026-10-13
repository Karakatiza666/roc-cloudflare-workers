platform ""
	requires {} { handle! : Str => Str }
	exposes [Wait]
	packages {}
	provides { "roc_handle": handle_for_host! }
	hosted { "roc_wait": Wait.wait! }
	targets: {
		inputs_dir: "targets/",
		wasm32: {
			inputs: ["host.wasm", app],
			output: Shared,
			exports: ["init", "handle", "task_abort", "task_waiting", "task_saved", "task_saved_max", "task_saved_peak", "task_waits", "stats_reset", "set_copy", "copy_bench", "live_bytes", "js_alloc", "res_free", "heap_used", "stack_canary_ok", "stack_first", "dealloc_miss", "alloc_bench", "heap_fill", "walk_bench"],
		},
	}

import Wait

handle_for_host! : Str => Str
handle_for_host! = |req| handle!(req)
