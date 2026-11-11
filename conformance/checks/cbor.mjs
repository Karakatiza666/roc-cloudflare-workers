// The platform module `Cbor` (a wrapper of roc-cbor 0.2.2): routes of conformance/CborRoutes.roc. The app has no `cbor`
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
  // roc-cbor 0.2.2: Err(Null) in a record field writes no key; a null is a missing key in a record; a Bool reads 0 and 1.
  // roc-cbor 0.5.0: Err(Null) in a record writes null and reads back strict as Err(Null). Strict: a null into ?: or
  // Try(a, [Missing]) is an error, and a Bool does not read 0 and 1. Cbor.js_values (a value from JS) reads the null as no key.
  ['cbor null: Err(Null) in a record writes null and reads back as Err(Null); strict null into ?: or Try Missing is an error; js_values reads it as absent; BoolFromInt reads 0 and 1', async (t) =>
    answer(await t.get('/cbor/null'), '[162, 98, 105, 100, 7, 100, 110, 111, 116, 101, 246] Ok({ id: 7, note: Err(Null) }) Err(InvalidCbor(10)) | Err(InvalidCbor(10)) Ok([Ok("a"), Err(Null)]) Err(InvalidCbor(3)) | js Ok(Err(MissingField)) Ok(Err(Missing)) Err(MissingRequiredField("note")) Ok([False, True, False, True])')],
  // The stack of the build (README.md, "Stack size"): a derived codec of a value nested 50 levels deep. In a --opt=dev build
  // the frames are large (roc-lang/roc#12922): 1 MiB fails at 50 levels, so bench/stack-modes.sh builds dev with 2 MiB.
  ['cbor nest: a value nested 50 levels deep encodes and reads back', async (t) =>
    answer(await t.get('/cbor/nest?n=50'), 'n=50 bytes=307 | same=True')],
];
