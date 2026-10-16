// `Request.Cf` (MODULES.md 4, PLAN.md 8c): conformance/CfRoutes.roc. run.mjs gives Miniflare a cf with `colo` and with
// no `metroCode`.
import { answer } from '../assert.mjs';

export const options = {};

export const checks = [
  ['request cf: colo Ok, a field that is not set Err(Missing)', async (t) =>
    answer(await t.get('/cf'), 'colo=Ok("DFW") metro_code=Err(Missing) asn=Ok(395747) is_eu_country=False')],
];
