import { readFileSync } from 'node:fs';
process.on('uncaughtException', (e) => { console.log(String(e).slice(0, 60)); process.exit(0); });
const v = process.argv[2];
const mod = await import('./workload.mjs?' + v).catch((e) => console.log('err', String(e).slice(0, 80)));
