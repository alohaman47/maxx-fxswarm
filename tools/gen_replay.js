'use strict';
// Build an anonymized historical exam for the AI.
// usage: node tools/gen_replay.js <csv folder> [--calls 1600] [--seed 7] [--from 2024-02-01] [--to 2026-10-20]
// Output: replay/replay_set.json (prompts + which real pair/bar each answer belongs to)
//
// Anti-memorization: pair names -> ASSET_1..5, no calendar date (weekday + NY clock only),
// every price rescaled so the last close = 1000.00. The AI sees the same features and the same
// system prompt as live; only the identifiers are hidden.

const fs = require('fs');
const path = require('path');
process.env.DATA_DIR = process.env.DATA_DIR || fs.mkdtempSync(path.join(require('os').tmpdir(), 'fxsw-'));
const { features } = require('../server.js');

const args = process.argv.slice(2);
const dir = args[0];
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const N_CALLS = parseInt(opt('--calls', '1600'), 10);
const OFF = parseFloat(opt('--offset', '7'));
const FROM = Date.parse(opt('--from', '2024-02-01') + 'T00:00:00Z') / 1000;
const TO = Date.parse(opt('--to', '2026-10-20') + 'T00:00:00Z') / 1000;
let seed = parseInt(opt('--seed', '7'), 10);
const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };

// load
const P = {};
for (const f of fs.readdirSync(dir).filter(f => /^[A-Z]{6}\.csv$/.test(f))) {
  const lines = fs.readFileSync(path.join(dir, f), 'utf8').split(/\r?\n/);
  let sym = f.slice(0, 6), point = 0.00001;
  const bars = []; const idx = new Map();
  for (const ln of lines) {
    if (ln.startsWith('#meta')) { const m = ln.split(','); sym = m[1]; point = +m[3]; continue; }
    const v = ln.split(','); if (!/^\d/.test(v[0])) continue;
    idx.set(+v[0], bars.length);
    bars.push({ t: +v[0], o: +v[1], h: +v[2], l: +v[3], c: +v[4], spr: (+v[5] || 0) * point });
  }
  P[sym] = { bars, idx };
}
const SYMS = Object.keys(P).sort();
const grid = P.EURUSD.bars.map(b => b.t).filter(t => t >= FROM && t <= TO);

function nyInfo(tDecision) { // decision happens at bar close
  const d = new Date((tDecision - OFF * 3600) * 1000);
  const wd = d.getUTCDay(), h = d.getUTCHours(), m = d.getUTCMinutes();
  return { wd, h, m, name: ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][wd] };
}
function allowed(ny) {
  if (ny.wd === 0 || ny.wd === 6) return false;
  if (ny.wd === 5 && ny.h >= 16) return false;
  if (ny.h >= 16 && ny.h < 19) return false;
  return true;
}
function atrAt(b, i, n = 14) { let s = 0; for (let k = i - n + 1; k <= i; k++) s += Math.max(b[k].h - b[k].l, Math.abs(b[k].h - b[k - 1].c), Math.abs(b[k].l - b[k - 1].c)); return s / n; }

const calls = []; const usedT = new Set(); let guard = 0;
while (calls.length < N_CALLS && guard++ < N_CALLS * 50) {
  const t = grid[Math.floor(rnd() * grid.length)];
  if (usedT.has(t)) continue;
  const ny = nyInfo(t + 900); if (!allowed(ny)) continue;
  const avail = SYMS.filter(s => { const i = P[s].idx.get(t); return i !== undefined && i >= 130 && i + 40 < P[s].bars.length; });
  if (avail.length < 5) continue;
  usedT.add(t);
  const pick = []; while (pick.length < 5) { const s = avail[Math.floor(rnd() * avail.length)]; if (!pick.includes(s)) pick.push(s); }
  const sess = ny.h >= 19 || ny.h < 3 ? 'Asia/Tokyo session (usually quieter, JPY/AUD/NZD most active)' : ny.h < 8 ? 'London session' : ny.h < 12 ? 'London-New York overlap' : 'New York afternoon';
  let prompt = `Time now New York ${ny.name} ${String(ny.h).padStart(2, '0')}:${String(ny.m).padStart(2, '0')} | ${sess}\n`;
  prompt += `(Instrument names are hidden and prices are rescaled so the last close = 1000.00; read the chart shape only.)\n`;
  const items = [];
  pick.forEach((sym, k) => {
    const b = P[sym].bars; const i = P[sym].idx.get(t);
    const scale = 1000 / b[i].c;
    const win = b.slice(i - 119, i + 1).map(x => ({ t: x.t, o: x.o * scale, h: x.h * scale, l: x.l * scale, c: x.c * scale }));
    const atrRaw = atrAt(b, i);
    const p = { d: 2, atr: atrRaw * scale, spr: b[i].spr * scale, bars: win };
    const f = features(p);
    const key = 'ASSET_' + (k + 1);
    prompt += `\n=== ${key} ===\nATR14 ${p.atr.toFixed(2)} | spread ${f.sprAtr} ATR | ${f.trend} | EMA20 slope ${f.slope} ATR per 5 bars | RSI14 ${f.rsi} | position in 20-bar range ${f.pos}\n`;
    prompt += `Last 6 H1 closes: ${f.h1}\n`;
    prompt += `M15 bars oldest->newest (o,h,l,c):\n`;
    for (const x of win.slice(-20)) prompt += [x.o, x.h, x.l, x.c].map(v => v.toFixed(2)).join(',') + '\n';
    items.push({ k: key, sym, t });
  });
  calls.push({ id: calls.length + 1, prompt, items });
}
fs.mkdirSync(path.join(__dirname, '..', 'replay'), { recursive: true });
const out = path.join(__dirname, '..', 'replay', 'replay_set.json');
fs.writeFileSync(out, JSON.stringify({ created: new Date().toISOString(), offset: OFF, calls }));
console.log(`wrote ${calls.length} calls (${calls.length * 5} decisions) -> ${out} ${(fs.statSync(out).size / 1e6).toFixed(1)} MB`);
const yrs = {}; for (const c of calls) { const y = new Date(c.items[0].t * 1000).getUTCFullYear(); yrs[y] = (yrs[y] || 0) + 1; }
console.log('per year', yrs);
