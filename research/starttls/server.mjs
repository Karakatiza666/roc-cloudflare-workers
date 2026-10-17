// The STARTTLS server of the probe. The code is in conformance/starttls-server.mjs (the local check of conformance/checks/tcp.mjs
// uses it too: PLAN.md EP11).
// CLI: node research/starttls/server.mjs <port> <cert.pem> <key.pem>   (for a run from another place: the edge)
import { readFileSync } from 'node:fs';
import { startServer } from '../../conformance/starttls-server.mjs';

export { startServer };

if (process.argv[1] === new URL(import.meta.url).pathname && process.argv[2]) {
  const [, , port, certFile, keyFile] = process.argv;
  const { log } = await startServer({ cert: readFileSync(certFile), key: readFileSync(keyFile), port: Number(port), host: '0.0.0.0' });
  setInterval(() => { for (const l of log.splice(0)) console.log(JSON.stringify(l)); }, 500);
  console.log(`listening on ${port}`);
}
