# workerd config of research/starttls/run-local.mjs: the probe worker, and an outbound network that trusts `out/cert.pem` (the
# test server) and allows local addresses, so `startTls()` to 127.0.0.1 can verify its certificate.
using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [
    (name = "main", worker = (modules = [
        (name = "worker.js", esModule = embed "worker.js"),
        (name = "js/helpers.js", esModule = embed "js/helpers.js"),
        (name = "js/events.js", esModule = embed "js/events.js"),
        (name = "js/options.js", esModule = embed "js/options.js"),
        (name = "js/runner.js", esModule = embed "js/runner.js"),
        (name = "js/wait.js", esModule = embed "js/wait.js"),
        (name = "js/host.js", esModule = embed "js/host.js"),
        (name = "js/tasks.js", esModule = embed "js/tasks.js"),
        (name = "js/budget.js", esModule = embed "js/budget.js"),
        (name = "js/bridge.js", esModule = embed "js/bridge.js"),
        (name = "js/program.js", esModule = embed "js/program.js"),
        (name = "js/values.js", esModule = embed "js/values.js"),
        (name = "js/cbor.js", esModule = embed "js/cbor.js")],
      compatibilityDate = "2026-10-01",
      globalOutbound = "net")),
    (name = "net", network = (allow = ["public", "private", "local"], tlsOptions = (trustedCertificates = [embed "out/cert.pem"]))),
  ],
  sockets = [ (name = "http", address = "127.0.0.1:8431", http = (), service = "main") ],
);
