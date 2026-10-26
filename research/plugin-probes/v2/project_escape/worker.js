// Written by hand: the app gives `ops` to makeHandler, so `sync` does not write this file.
import app from './app.wasm';
import { makeHandler } from './.roc-cfw/index.js';

export default makeHandler(app, {
  ops: { slugify: async (s) => s.toLowerCase().replaceAll(' ', '-') },
});
