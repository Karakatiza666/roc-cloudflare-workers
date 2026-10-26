// Made by roc-cloudflare-workers sync from the manifest of the app. Run it again after a change of the classes in Roc.
import app from './ledger.wasm';
import { makeHandler } from '../../js/index.js';

export default makeHandler(app);
