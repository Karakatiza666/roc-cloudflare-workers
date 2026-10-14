using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [
    (name = "main", worker = (modules = [(name = "worker.js", esModule = embed "worker.js"), (name = "m.wasm", wasm = embed "m.wasm"), (name = "big.wasm", wasm = embed "big.wasm")],
      compatibilityDate = "2026-10-01", compatibilityFlags = ["enable_request_signal"], bindings = [(name = "SLOW", service = "slow")])),
    (name = "slow", worker = (modules = [(name = "slow.js", esModule = embed "slow.js")], compatibilityDate = "2026-10-01", compatibilityFlags = ["enable_request_signal"])),
  ],
  sockets = [ (name = "http", address = "127.0.0.1:8231", http = (), service = "main") ],
  v8Flags = ["--expose-gc"],
);
