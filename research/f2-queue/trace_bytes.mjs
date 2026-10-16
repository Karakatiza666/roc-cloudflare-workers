// Makes the CBOR bytes of two trace items for the `expect`s of `platform/Worker.roc` (PLAN.md 8f): the shim writes them
// the same way (`js/events.js` `tailEvent`). Run: node research/f2-queue/trace_bytes.mjs
import { tailEvent } from '../../js/events.js';
import { pack, decode } from '../../js/values.js';

const items = [
  { scriptName: 'w', outcome: 'exception', eventTimestamp: 1700000000000, event: { request: { url: 'http://x/', method: 'GET', headers: { a: 'b' } }, response: { status: 500 } }, logs: [{ timestamp: 5, level: 'log', message: ['a', 1] }], exceptions: [{ timestamp: 6, name: 'Error', message: 'boom' }] },
  { scriptName: null, outcome: 'ok', eventTimestamp: 1700000000001, event: { cron: '* * * * *', scheduledTime: 5 }, logs: [], exceptions: [] },
];
const ev = tailEvent(items);
const bytes = pack(ev.items.value);
// tag 24, then a byte string head
let i = 2;
const head = bytes[i++];
const n = head === 0x58 ? bytes[i++] : head === 0x59 ? (bytes[i++] << 8) | bytes[i++] : 0;
const content = bytes.slice(i, i + n);
console.log(`[${[...content].map((b) => '0x' + b.toString(16).padStart(2, '0')).join(', ')}]`);
