// Probe: which Workers runtime features can the platform use with no wasm code of its own?
async function tryIt(name, f) {
  try { return [name, 'yes', String(await f())]; } catch (e) { return [name, 'no', `${e.name}: ${e.message}`]; }
}
const zstdHello = new Uint8Array([0x28,0xb5,0x2f,0xfd,0x04,0x58,0x29,0x00,0x00,0x68,0x65,0x6c,0x6c,0x6f,0x0a,0x7d,0x6e,0x2e,0x19]);
export default {
  async fetch(req, env, ctx) {
    const rows = await Promise.all([
      tryIt('DecompressionStream gzip', () => { new DecompressionStream('gzip'); return 'ctor ok'; }),
      tryIt('DecompressionStream zstd', async () => {
        const s = new Blob([zstdHello]).stream().pipeThrough(new DecompressionStream('zstd'));
        return JSON.stringify(await new Response(s).text());
      }),
      tryIt('Ed25519 sign', async () => {
        const k = await crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']);
        const sig = await crypto.subtle.sign('Ed25519', k.privateKey, new TextEncoder().encode('x'));
        return sig.byteLength + ' B';
      }),
      tryIt('RSASSA-PKCS1-v1_5 verify (JWT RS256)', async () => {
        const k = await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1,0,1]), hash: 'SHA-256' }, true, ['sign', 'verify']);
        const d = new TextEncoder().encode('x');
        const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', k.privateKey, d);
        return await crypto.subtle.verify('RSASSA-PKCS1-v1_5', k.publicKey, sig, d);
      }),
      tryIt('ECDSA P-256 verify', async () => {
        const k = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
        const d = new TextEncoder().encode('x');
        const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, k.privateKey, d);
        return await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, k.publicKey, sig, d);
      }),
      tryIt('crypto.DigestStream SHA-256', async () => {
        const ds = new crypto.DigestStream('SHA-256');
        const w = ds.getWriter(); await w.write(new TextEncoder().encode('abc')); await w.close();
        return [...new Uint8Array(await ds.digest)].map(b => b.toString(16).padStart(2, '0')).join('').slice(0, 16) + '...';
      }),
      tryIt('crypto.subtle.digest BLAKE3', async () => (await crypto.subtle.digest('BLAKE3', new Uint8Array(1))).byteLength),
      tryIt('timingSafeEqual', () => crypto.subtle.timingSafeEqual(new Uint8Array(4), new Uint8Array(4))),
      tryIt('Date.now frozen in a request', async () => { const a = Date.now(); let x = 0; for (let i = 0; i < 3e7; i++) x += i; return Date.now() - a + ' ms after a busy loop'; }),
    ]);
    return new Response(rows.map(r => r.join(' | ')).join('\n') + '\n');
  },
};
