// Shared code of the bench: read the rows file, CSV export, the row key.
import { readFileSync, existsSync } from 'node:fs';

export const COLUMNS = ['commit', 'date', 'nightly', 'label', 'where', 'scenario', 'metric', 'value', 'unit', 'requests', 'rounds', 'min', 'max', 'source'];

export function readRows(file) {
  if (!existsSync(file)) return [];
  return readFileSync(file, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
}

const cell = (v) => (v === undefined || v === null ? '' : /[",\n]/.test(String(v)) ? `"${String(v).replaceAll('"', '""')}"` : String(v));
export const toCsv = (rows) => `${COLUMNS.join(',')}\n${rows.map((r) => COLUMNS.map((c) => cell(typeof r[c] === 'number' ? Number(r[c].toPrecision(10)) : r[c])).join(',')).join('\n')}\n`;

// One run is the rows with the same commit and date. Gives [{ commit, date, rows, get(scenario, metric) }] in file order.
export function runsOf(rows) {
  const map = new Map();
  for (const r of rows) {
    const k = `${r.commit}|${r.date}|${r.where ?? 'local'}`;
    if (!map.has(k)) map.set(k, { where: r.where ?? 'local', commit: r.commit, date: r.date, label: r.label, nightly: r.nightly, rows: [] });
    map.get(k).rows.push(r);
  }
  return [...map.values()].map((run) => ({ ...run, get: (sc, m) => run.rows.find((r) => r.scenario === sc && r.metric === m)?.value }));
}
