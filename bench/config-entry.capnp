# PLAN.md 8b (first half) in workerd: bench/app_events.wasm (bench/events-worker.js) behind an entry service that serves
# the scheduled path of Miniflare (bench/entry-worker.js). bench/entry-workerd.mjs runs it on port 8135.
using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [
    (name = "main", worker = (modules = [
        (name = "entry-worker.js", esModule = embed "entry-worker.js")],
      compatibilityDate = "2026-10-01",
      compatibilityFlags = ["service_binding_extra_handlers"],
      bindings = [(name = "APP", service = "app")])),
    (name = "app", worker = (modules = [
        (name = "events-worker.js", esModule = embed "events-worker.js"),
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
        (name = "app_events.wasm", wasm = embed "out/app_events.wasm")],
      compatibilityDate = "2026-10-01",
      compatibilityFlags = ["enable_request_signal"])),
  ],
  sockets = [ (name = "http", address = "127.0.0.1:8135", http = (), service = "main") ],
);
