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
			# Stack: 1 MB, read by hostlib/canary.zig from the linker. Memory: sized by the linker. No maximum (PLAN.md M5).
			initial_stack_size: 1048576,
			minimum_memory: 0,
			exports: ["init", "handle", "task_abort", "task_cancel", "task_slots", "task_waiting", "task_saved", "task_saved_max", "task_saved_peak", "task_waits", "stats_reset", "set_copy", "copy_bench", "live_bytes", "js_alloc", "res_free", "heap_used", "stack_canary_ok", "stack_first", "dealloc_miss", "alloc_bench", "heap_fill", "walk_bench", "set_free_mark", "fail_next_alloc", "fail_alloc_at", "fault_next_wait", "log_ptr", "log_len", "log_clear", "trap_cause", "set_sum", "set_suspect", "sum_checks", "alarms", "set_wild", "poke_wait", "check_heap", "break_table", "__instance_signal", "__instance_terminated"],
		},
	}

import Wait

handle_for_host! : Str => Str
handle_for_host! = |req| handle!(req)
