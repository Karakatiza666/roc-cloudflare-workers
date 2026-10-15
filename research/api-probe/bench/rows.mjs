// node rows.mjs: write the 200 rows of main.roc in the Js byte format to rows.bin (same bytes as main.roc builds).
import { writeFileSync } from 'node:fs';
import { encode } from '../codec.mjs';
const h = 'A'.repeat(44);
const rows = Array.from({ length: 200 }, (_, i) => ['roc-lang/http', `1.${i}.0`, h, `https://github.com/roc-lang/http/releases/download/1.${i}.0/${h}.tar.zst`, 1760000000 + i, 184000 + i, 0, '{"workflow":"release.yml"}']);
const b = encode(rows);
writeFileSync(new URL('./rows.bin', import.meta.url), b);
console.log(`rows.bin: ${b.length} B`);
