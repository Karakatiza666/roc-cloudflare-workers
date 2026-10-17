# STARTTLS probe (PLAN.md 11c, EP6, E47)

Question: on the edge, a `tls: StartTls` socket reads its banner, and then the next `write!` and `read!` wait with no end (E47). Does the shim (`js/helpers.js`: `tcpRead`, `tcpWrite`, `tcpStartTls`) or the runtime cause it?

| File | What |
| --- | --- |
| `worker.js` | Two routes with the same steps (banner, EHLO, STARTTLS, TLS upgrade, EHLO). `/raw`: `connect` of `cloudflare:sockets`, no shim. `/shim`: the real helpers of `js/helpers.js` (`makeHelpers`). Each step has a timeout of 5 s, so a hang is a line `timeout` |
| `server.mjs` | The CLI of the STARTTLS server. The server (SMTP-like, Node `net` and `tls`, it logs what it received) is in `conformance/starttls-server.mjs`, which the conformance check of EP11 uses too |
| `run-local.mjs` | Local run: certificate (`openssl`), the server, the local workerd (`config.capnp`: an outbound network that trusts the test certificate), 9 variants, a block of steps for each |
| `wrangler.toml` | The edge run (not done) |
| `js` | A link to `../../js` (the shim, for the import of `worker.js` and for `wrangler`) |

Run locally: `WORKERD=<workerd> node research/starttls/run-local.mjs`. Needs `openssl`, port 8431, `out/` (git-ignored, the certificate).

## Local results (the workerd of the global wrangler, 2026-10-17)

| Variant | Result |
| --- | --- |
| `/raw` starttls, `allowHalfOpen` false (as the shim), not given, true | All steps pass, also the upgrade and the EHLO in TLS |
| `/raw` starttls, a new reader and writer for each step | Passes |
| `/raw` starttls, EHLO written before the banner is read | Passes |
| `/raw` off (control) | Passes |
| `/shim` starttls: connect, read, write, read, write, read | Passes (no hang after the first read) |
| The full platform (`Tcp.connect_with!` with `tls: StartTls`, two rounds of `write!` and `read!`, a Roc program under JSPI), conformance check `tcp connect_with! tls StartTls: write! and read! twice before start_tls!` | Passes |
| `/shim` starttls: `tcpStartTls` | Timeout before the fix of EP11 (the server did the upgrade, and the client never finished the handshake). Passes after the fix (2026-10-17) |
| `/raw` starttls with the reader and the writer locked at `startTls()` | The same timeout: `startTls()` returns, `opened` of the new socket never settles |
| `/raw` starttls with the locks released before `startTls()` | Passes |

So locally:

| Finding | Meaning |
| --- | --- |
| The steps after the first read work in starttls mode, in `/raw`, in `/shim` and in the full platform | The wait of E47 does not come from the shim code of `tcpRead` and `tcpWrite`, nor from the Roc layer, nor from the options of `connect`. It needs the edge. |
| `tcpStartTls` hangs because the shim keeps the reader and the writer locked (`tcpOf` in `js/helpers.js`) | A shim bug, found here (PLAN.md EP11). Fixed 2026-10-17: `tcpStartTls` releases both locks before `socket.startTls()` (and refuses a read in flight and unread bytes), checked by the conformance checks "tcp start_tls! ...". It is not the cause of E47: E47 hangs before `start_tls!`. |

## Edge run (needs an account, not done)

What it needs: a Cloudflare account (the Free plan was enough for `connect` in 11c), `wrangler` logged in, a STARTTLS server on the internet (`smtp.gmail.com:587` worked for E47; for a server log run `node server.mjs <port> <cert.pem> <key.pem>` on a host with a public port, or a TCP tunnel).

```
cd research/starttls && wrangler deploy
curl "$URL/raw?host=smtp.gmail.com&port=587&upgrade=0"
curl "$URL/raw?host=smtp.gmail.com&port=587&upgrade=0&half=none"
curl "$URL/raw?host=smtp.gmail.com&port=587&upgrade=0&relock=1"
curl "$URL/raw?host=smtp.gmail.com&port=587&upgrade=0&mode=off"       # control
curl "$URL/shim?host=smtp.gmail.com&port=587&upgrade=0"
curl "$URL/raw?host=smtp.gmail.com&port=587"                           # with the upgrade
wrangler delete
```

How to read the answers:

| `/raw` starttls | `/shim` starttls | `mode=off` | Cause |
| --- | --- | --- | --- |
| times out after the banner | times out | passes | The runtime of the edge (starttls mode), not the shim. Try `half=none`, `relock=1` and a server of your own (the log shows if the EHLO arrived: a write that hangs, or a read) |
| passes | times out | passes | The shim (`tcpRead` or `tcpWrite`), a difference that the local run does not show |
| passes | passes | passes | Not the shim and not the runtime alone. The Roc layer works locally (see above), so look at `edge/EdgeRoutes.roc` (`/edge/starttls`): run it again with `Log.info!` lines between the steps |
