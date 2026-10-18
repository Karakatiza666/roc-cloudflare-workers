// `Log` (MODULES.md 11): routes of conformance/LogRoutes.roc. Each call writes one JSON line with the level of its
// console method. `t.logs` has the structured log lines of workerd.
import { answer, eq, ok } from '../assert.mjs';

export const options = {};

const line = async (t, level, n) => {
  const id = `${level}-${Math.random().toString(36).slice(2)}`;
  answer(await t.get(`/log/${level}?id=${id}`), 'logged');
  const want = `{"level":"${level}","msg":"conformance ${id}","n":${n},"route":"${level}"}`;
  // workerd writes a line after the response: wait for it.
  for (let i = 0; i < 50 && !t.logs.some((l) => l.message.includes(id)); i++) await new Promise((r) => setTimeout(r, 20));
  const got = t.logs.find((l) => l.message.includes(id));
  ok(got, `no log line with ${id}`);
  ok(got.message.trim() === want && got.level === level, `got ${got.level} ${got.message.trim()}, want ${level} ${want}`);
  return `${got.level} ${got.message.trim()}`;
};

// workerd writes a line after the response: wait for it.
const wait = async (t, id) => {
  for (let i = 0; i < 50 && !t.logs.some((l) => l.message.includes(id)); i++) await new Promise((r) => setTimeout(r, 20));
  const got = t.logs.find((l) => l.message.includes(id));
  ok(got, `no log line with ${id}`);
  return got;
};

export const checks = [
  ['log info!', (t) => line(t, 'info', 7)],
  ['log warn!', (t) => line(t, 'warn', 8)],
  ['log error!', (t) => line(t, 'error', 9)],
  ['log an F64 field is in the line', async (t) => {
    const id = `f64-${Math.random().toString(36).slice(2)}`;
    answer(await t.get(`/log/f64?id=${id}`), 'logged');
    const got = await wait(t, id);
    eq(got.message.trim(), `{"level":"info","msg":"conformance ${id}","r":0.5,"route":"f64"}`);
  }],
  ['log a NaN field: one line with fields_error, the call does not fail', async (t) => {
    const id = `nan-${Math.random().toString(36).slice(2)}`;
    answer(await t.get(`/log/f64_nan?id=${id}`), 'logged');
    const got = await wait(t, id);
    eq(got.message.trim(), `{"level":"warn","msg":"conformance ${id}","fields_error":"NaN"}`);
    eq(got.level, 'warn', 'level');
  }],
];
