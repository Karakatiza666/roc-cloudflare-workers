# Variant b with the compatibility flag enable_request_signal (PLAN.md 3b): bench/signal-workerd.mjs.
using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [
    (name = "main", worker = (modules = [
        (name = "worker.js", esModule = embed "worker.js"),
        (name = "core.js", esModule = embed "core.js"),
        (name = "tasks.js", esModule = embed "tasks.js"),
        (name = "app.wasm", wasm = embed "out/app.wasm"),
        (name = "app_pad.wasm", wasm = embed "out/app_pad.wasm")],
      compatibilityDate = "2026-10-01",
      compatibilityFlags = ["enable_request_signal"],
      bindings = [(name = "ECHO", service = "echo"), (name = "VARIANT", text = "b"), (name = "PAD", fromEnvironment = "PAD")])),
    (name = "echo", worker = (modules = [(name = "echo.js", esModule = embed "echo.js")], compatibilityDate = "2026-10-01")),
  ],
  sockets = [ (name = "http", address = "127.0.0.1:8132", http = (), service = "main") ],
);
