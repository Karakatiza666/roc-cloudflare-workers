platform ""
	requires { event! : Worker.Event => Worker.Outcome }
	exposes [Bytes, Js, Io, Native, Worker, Request, Response, Body, Ctx, Queue, Email, Object, WebSocket, Http, Env, Secret, Time, Log, RateLimit, WebCrypto, R2, Cache, Sql, D1, Memo]
	packages {
		http: "https://github.com/roc-lang/http/releases/download/2.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
		cbor: "https://github.com/Karakatiza666/roc-cbor/releases/download/0.1.0/9QL2dCyq7bcmvAEZfDFwi8kBvWLCZpEMS4WQYnZisezw.tar.zst",
	}
	provides { "roc_event": event_for_host! }
	hosted { "roc_await": Host.await!, "roc_call": Host.call!, "roc_native": Host.native! }
	targets: {
		inputs_dir: "targets/",
		wasm32: {
			inputs: ["host.wasm", app],
			output: Shared,
			# The bench exports (PLAN.md 7a): the production exports of platform/main.roc, then the test exports.
			# Only `exports:` differs from platform/main.roc: bench/exports-test.mjs checks it.
			# Stack: 1 MB, read by hostlib/canary.zig from the linker. Memory: sized by the linker. No maximum (PLAN.md M5).
			initial_stack_size: 1048576,
			minimum_memory: 0,
			exports: ["init", "handle", "task_abort", "task_cancel", "task_slots", "js_alloc", "res_free", "stack_first", "set_free_mark", "set_grow_step", "check_heap", "log_ptr", "log_len", "log_clear", "heap_used", "heap_bytes", "live_bytes", "live_peak", "reclaim_walks", "reclaim_bytes", "leaked_at_end", "idle_resets", "idle_reset_bytes", "alarms", "sum_checks", "double_frees", "dealloc_miss", "idle_reset", "trap_cause", "set_sum", "set_suspect", "__instance_signal", "__instance_terminated", "task_waiting", "task_saved", "task_saved_max", "task_saved_peak", "task_waits", "stats_reset", "set_copy", "copy_bench", "stack_canary_ok", "alloc_bench", "heap_fill", "walk_bench", "fail_next_alloc", "fail_alloc_at", "alloc_count", "fault_next_wait", "set_wild", "poke_wait", "break_table", "leak_next", "bad_free", "cbor_check", "cbor_echo", "native_slots", "native_reown"],
		},
	}

import cbor.Cbor
import Js
import Io
import Native
import Host
import Worker
import Request
import Response
import Body
import Ctx
import Queue
import Email
import Object
import WebSocket
import Http
import Env
import Secret
import Time
import Log
import RateLimit
import WebCrypto
import R2
import Cache
import Sql
import D1
import Memo
import Entry

## API.md 4: the host decodes the event bytes into a `Js` value, and encodes the result for JS.
event_for_host! : Js => Js
event_for_host! = |js| Entry.outcome(event!(Entry.event(js)))

## A type alias of the platform root, listed in exposes.
Bytes : Cbor.Bytes
