// auction-web entry. Build the app first: roc build --target=wasm32 --no-cache --output=web.wasm web.roc
import app from './web.wasm';
import { makeHandler, objectClass } from 'roc-cloudflare-workers';

// One line for each Durable Object class of Worker.objects. It comes before the default export.
export const LotRoom = objectClass('LotRoom');

export default makeHandler(app);
