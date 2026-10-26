// Made by roc-cloudflare-workers sync from the manifest of the app. Run it again after a change of the classes in Roc.
import app from './web.wasm';
import { makeHandler, objectClass } from '../../js/index.js';

export const LotRoom = objectClass('LotRoom');

export default makeHandler(app);
