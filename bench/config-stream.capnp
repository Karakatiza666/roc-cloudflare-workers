# PLAN.md 8b (second half), 9c, 10a, 10b in workerd: bench/app_stream.wasm (bench/stream-worker.js).
# bench/stream-workerd.mjs runs it on port 8136. The flag enable_request_signal: the client that goes away (PLAN.md 3b).
using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [
    (name = "main", worker = (modules = [
        (name = "stream-worker.js", esModule = embed "stream-worker.js"),
        (name = "js/index.js", esModule = embed "../js/index.js"),
        (name = "js/events.js", esModule = embed "../js/events.js"),
        (name = "js/options.js", esModule = embed "../js/options.js"),
        (name = "js/runner.js", esModule = embed "../js/runner.js"),
        (name = "js/wait.js", esModule = embed "../js/wait.js"),
        (name = "js/host.js", esModule = embed "../js/host.js"),
        (name = "js/tasks.js", esModule = embed "../js/tasks.js"),
        (name = "js/budget.js", esModule = embed "../js/budget.js"),
        (name = "js/manifest.js", esModule = embed "../js/manifest.js"),
        (name = "js/bindings.js", esModule = embed "../js/bindings.js"),
        (name = "js/bridge.js", esModule = embed "../js/bridge.js"),
        (name = "js/program.js", esModule = embed "../js/program.js"),
        (name = "js/helpers.js", esModule = embed "../js/helpers.js"),
        (name = "js/values.js", esModule = embed "../js/values.js"),
        (name = "js/cbor.js", esModule = embed "../js/cbor.js"),
        (name = "app_stream.wasm", wasm = embed "out/app_stream.wasm")],
      compatibilityDate = "2026-10-01",
      compatibilityFlags = ["enable_request_signal"])),
  ],
  sockets = [ (name = "http", address = "127.0.0.1:8136", http = (), service = "main") ],
);
