# Probe of research/chunk-fill: probe-worker.js on port 8191, with access to 127.0.0.1 (the Node server of probe.mjs).
using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [
    (name = "main", worker = (modules = [(name = "probe-worker.js", esModule = embed "probe-worker.js")],
      compatibilityDate = "2026-10-01", globalOutbound = "net")),
    (name = "net", network = (allow = ["public", "private", "local"])),
  ],
  sockets = [ (name = "http", address = "127.0.0.1:8191", http = (), service = "main") ],
);
