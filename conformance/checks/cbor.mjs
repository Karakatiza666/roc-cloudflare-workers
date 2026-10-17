// The platform module `Cbor` (a wrapper of roc-cbor 0.1.0): routes of conformance/CborRoutes.roc. The app has no `cbor`
// entry in its header, so these checks also show that an app needs none.
import { answer } from '../assert.mjs';

export const options = {};

export const checks = [
  // `Cbor.Bytes` writes a byte string: the head 0x43 (67) before 1, 2, 3 (an array of numbers would be 0x83).
  ['cbor bytes: a Cbor.Bytes field is a byte string and reads back', async (t) =>
    answer(await t.get('/cbor/bytes'), '[163, 102, 97, 118, 97, 116, 97, 114, 67, 1, 2, 3, 98, 105, 100, 7, 100, 110, 97, 109, 101, 97, 120] | Ok([1, 2, 3])')],
  ['cbor generic: a function with Cbor.Encodable and Cbor.Parseable in its where clause', async (t) =>
    answer(await t.get('/cbor/generic'), 'Ok([1, 2, 3])')],
  ['cbor custom: a parser_for of the app with Cbor.Format and Cbor.State', async (t) =>
    answer(await t.get('/cbor/custom'), 'Ok({ tag: "id-1" }) | Err(InvalidCbor(5))')],
  ['cbor options: parse_camel and parse_with read userId, parse does not', async (t) =>
    answer(await t.get('/cbor/options'), 'Ok({ user_id: 5 }) Ok({ user_id: 5 }) | Err(MissingRequiredField("user_id"))')],
  ['cbor path: path_at finds the field of an InvalidCbor position', async (t) =>
    answer(await t.get('/cbor/path'), 'Err(InvalidCbor(5)) | Ok([Index(0), Key("id")])')],
];
