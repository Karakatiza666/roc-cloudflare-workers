// auction-ledger entry. Build the app first: roc build --target=wasm32 --no-cache --output=ledger.wasm ledger.roc
import app from './ledger.wasm';
import { makeHandler } from 'roc-cloudflare-workers';

// The default export is a WorkerEntrypoint: auction-web calls settle_due on it through a service binding.
export default makeHandler(app);
