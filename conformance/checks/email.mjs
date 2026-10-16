// `Email` (MODULES.md 13, PLAN.md 8f): the `email!` handler and the routes of conformance/EmailRoutes.roc. A mail is sent
// to `/cdn-cgi/local/email` of Miniflare (`format=json`), which answers the outcome, the forwards, the replies and the
// reject reason of the handler. The routes send with the binding `EMAIL` (`send_email` of Miniflare).
import { answer, eq, ok } from '../assert.mjs';

export const options = { email: { send_email: [{ name: 'EMAIL' }] } };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const rawMail = (to, subject = 'hello', id = `<${Math.random().toString(36).slice(2)}@example.com>`) =>
  `From: sender@example.com\r\nTo: ${to}\r\nSubject: ${subject}\r\nMessage-ID: ${id}\r\nDate: Thu, 15 Oct 2026 10:00:00 +0000\r\nContent-Type: text/plain\r\n\r\nthe body\r\n`;
// The mail goes to the address `to`, and the handler does what that address says.
async function mail(t, to, subject, body = rawMail(to, subject)) {
  const r = await t.mf.dispatchFetch(`http://localhost/cdn-cgi/local/email?from=sender%40example.com&to=${encodeURIComponent(to)}&format=json`, { method: 'POST', body });
  const text = await r.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = { text };
  }
  return { status: r.status, ...json };
}
const headerOf = (f, name) => (f.headers ?? []).find(([k]) => k.toLowerCase() === name.toLowerCase())?.[1];

export const checks = [
  ['email forward!: the mail goes to the address', async (t) => {
    const r = await mail(t, 'fwd@example.com');
    eq(r.outcome, 'ok', 'outcome');
    eq(JSON.stringify(r.forwards.map((f) => f.recipient)), JSON.stringify(['dest@example.com']), 'forwards');
    const io = await mail(t, 'fwd-io@example.com');
    eq(JSON.stringify(io.forwards.map((f) => f.recipient)), JSON.stringify(['dest@example.com']), 'forward (Io twin)');
  }],
  // PLAN.md 8f: `Email.Mail.forward_with!` with an `X-Test` header.
  ['email forward_with!: an X-Test header', async (t) => {
    const r = await mail(t, 'fwd-x@example.com');
    eq(r.outcome, 'ok', 'outcome');
    eq(r.forwards.length, 1, 'forwards');
    eq(headerOf(r.forwards[0], 'x-test'), 'yes', 'the X-Test header');
    const io = await mail(t, 'fwd-x-io@example.com');
    eq(headerOf(io.forwards[0], 'x-test'), 'io', 'the X-Test header (Io twin)');
    return JSON.stringify(r.forwards[0].headers);
  }],
  ['email header: the case does not matter, a missing header is Missing', async (t) => {
    const r = await mail(t, 'fwd-subject@example.com', 'a subject');
    eq(r.outcome, 'ok', 'outcome');
    eq(headerOf(r.forwards[0], 'x-subject'), 'a subject', 'SUBJECT');
    eq(headerOf(r.forwards[0], 'x-none'), 'missing', 'x-none');
  }],
  ['email set_reject!: the mail is rejected with the reason', async (t) => {
    const r = await mail(t, 'reject@example.com');
    eq(r.rejectReason, 'no thanks', 'reason');
    eq((await mail(t, 'reject-io@example.com')).rejectReason, 'no thanks io', 'reason (Io twin)');
  }],
  ['email reply!: a reply to the sender', async (t) => {
    const r = await mail(t, 'reply@example.com');
    eq(r.outcome, 'ok', `outcome ${JSON.stringify(r).slice(0, 300)}`);
    eq(r.replies.length, 1, 'replies');
    eq(r.replies[0].sender, 'reply@example.com', 'the sender of the reply');
    const io = await mail(t, 'reply-io@example.com');
    eq(io.replies.length, 1, 'replies (Io twin)');
  }],
  ['email an Err of email! rejects the mail (a throw)', async (t) => {
    const r = await mail(t, 'err@example.com');
    eq(r.outcome, 'exception', 'outcome');
    eq(r.status, 500, 'status');
    const none = await mail(t, 'other@example.com');
    eq(none.outcome, 'ok', 'a mail with no action is accepted');
  }],
  ['email raw, raw_size_bytes, can_be_forwarded, from', async (t) => {
    const raw = rawMail('raw@example.com', 'size');
    const r = await mail(t, 'raw@example.com', 'size', raw);
    eq(r.outcome, 'ok', 'outcome');
    let line;
    for (let i = 0; i < 200 && !line; i++) {
      line = t.logs.map((l) => { try { return JSON.parse(l.message); } catch { return null; } }).find((l) => l?.msg === 'mail raw');
      if (!line) await sleep(25);
    }
    ok(line, 'no log line of the handler');
    eq(JSON.stringify([line.size, line.chars, line.from, line.can_forward]), JSON.stringify([raw.length, raw.length, 'sender@example.com', true]), 'the fields');
  }],
  ['email send!, send (Io twin) and send_raw!, send_raw (Io twin) give a message id', async (t) => {
    answer(await t.get('/email/send?subject=hi'), 'Ok id');
    answer(await t.get('/email/send_io?subject=hi'), 'Ok id');
    answer(await t.get('/email/send_raw?subject=raw'), 'Ok id');
    answer(await t.get('/email/send_raw_io?subject=rawio'), 'Ok id');
  }],
];
