# Variant b with the compatibility flag enable_request_signal (PLAN.md 3b): bench/signal-workerd.mjs.
using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [
    (name = "main", worker = (modules = [
        (name = "worker.js", esModule = embed "worker.js"),
        (name = "check.js", esModule = embed "check.js"),
        (name = "js/index.js", esModule = embed "../js/index.js"),
        (name = "js/events.js", esModule = embed "../js/events.js"),
        (name = "js/options.js", esModule = embed "../js/options.js"),
        (name = "js/runner.js", esModule = embed "../js/runner.js"),
        (name = "js/wait.js", esModule = embed "../js/wait.js"),
        (name = "js/host.js", esModule = embed "../js/host.js"),
        (name = "js/tasks.js", esModule = embed "../js/tasks.js"),
        (name = "js/budget.js", esModule = embed "../js/budget.js"),
        (name = "js/bridge.js", esModule = embed "../js/bridge.js"),
        (name = "js/program.js", esModule = embed "../js/program.js"),
        (name = "js/helpers.js", esModule = embed "../js/helpers.js"),
        (name = "js/values.js", esModule = embed "../js/values.js"),
        (name = "js/cbor.js", esModule = embed "../js/cbor.js"),
        (name = "app.wasm", wasm = embed "out/app.wasm"),
        (name = "app_pad.wasm", wasm = embed "out/app_pad.wasm")],
      compatibilityDate = "2026-10-01",
      compatibilityFlags = ["enable_request_signal"],
      bindings = [(name = "ECHO", service = "echo"), (name = "VARIANT", text = "b"), (name = "PAD", fromEnvironment = "PAD")])),
    (name = "echo", worker = (modules = [(name = "echo.js", esModule = embed "echo.js")], compatibilityDate = "2026-10-01")),
  ],
  sockets = [ (name = "http", address = "127.0.0.1:8132", http = (), service = "main") ],
);
