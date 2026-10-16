using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [
    (name = "main", worker = (modules = [(name = "worker.js", esModule = embed "worker.js")],
      compatibilityDate = "2026-10-01", compatibilityFlags = [])),
  ],
  sockets = [ (name = "http", address = "127.0.0.1:8242", http = (), service = "main") ],
);
