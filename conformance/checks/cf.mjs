// `Request.Cf` (MODULES.md 4, PLAN.md 8c): conformance/CfRoutes.roc. run.mjs gives Miniflare a cf with `colo` and with
// no `metroCode`.
import { answer, ok } from '../assert.mjs';

export const options = {};

export const checks = [
  // Edge form (`t.edge`, PLAN.md 11c): the cf of the real place of the client: a colo of 3 letters, an asn, and a
  // metro_code that is set only in the US.
  ['request cf: colo Ok, a field that is not set Err(Missing)', async (t) => {
    const r = await t.get('/cf');
    if (!t.edge) return answer(r, 'colo=Ok("DFW") metro_code=Err(Missing) asn=Ok(395747) is_eu_country=False');
    ok(r.status === 200 && /^colo=Ok\("[A-Z]{3}"\) metro_code=(Err\(Missing\)|Ok\("\d+"\)) asn=Ok\(\d+\) is_eu_country=(True|False)$/.test(r.body), `got ${r.status} ${r.body} (edge form)`);
    return r.body;
  }],
];
