'use strict';
// MAXX FX SWARM - history replay of the technique lab.
// Uses techniques.js (same rules as the live server) + the same ATR exit engine.
//
// usage: node backtest.js <folder with SYMBOL.csv files> [--split 2026-01-01] [--offset 7] [--comm 0.7]
// CSV (from MAXX_FXSWARM_EXPORT_v1.mq5):
//   #meta,EURUSD,5,0.00001
//   time,open,high,low,close,spread      (time = epoch seconds, MT5 server clock; spread in points)

const fs = require('fs');
const path = require('path');
const TECH = require('./techniques');

const args = process.argv.slice(2);
const dir = args[0];
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const SPLIT = Date.parse(opt('--split', '2026-01-01') + 'T00:00:00Z') / 1000;
const OFF = parseFloat(opt('--offset', '7'));
const COMM_PIPS = parseFloat(opt('--comm', '0.7'));
const NOSPREAD = args.includes('--gross');     // Razor commission ~$7/lot round trip = 0.7 pip
const WIN = 300;
const TF = parseInt(opt('--tf', '15'), 10);       // 15 = M15 as exported, 60 = H1, 240 = H4
const X = { sl: 1.0, be: 1.0, trailStart: 1.5, trailDist: 1.0, tp: 3.0, maxBars: parseInt(opt('--maxbars', '32'), 10) };
if (!dir) { console.error('usage: node backtest.js <csv folder>'); process.exit(1); }

function load(file) {
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean);
  let sym = path.basename(file).replace(/\.csv$/i, '').replace(/_M15$/i, ''), digits = 5, point = 0.00001;
  const bars = [];
  for (const ln of lines) {
    if (ln.startsWith('#meta')) { const f = ln.split(','); sym = f[1]; digits = +f[2]; point = +f[3]; continue; }
    const f = ln.split(','); if (!/^\d/.test(f[0])) continue;
    bars.push({ t: +f[0], o: +f[1], h: +f[2], l: +f[3], c: +f[4], spr: NOSPREAD ? 0 : (+f[5] || 0) * point });
  }
  bars.sort((a, b) => a.t - b.t);
  if (TF > 15) { // aggregate M15 -> higher timeframe (bar time = bucket start, spread = max in bucket)
    const out = []; const sec = TF * 60;
    for (const b of bars) {
      const k = Math.floor(b.t / sec) * sec; const last = out[out.length - 1];
      if (last && last.t === k) { last.h = Math.max(last.h, b.h); last.l = Math.min(last.l, b.l); last.c = b.c; last.spr = Math.max(last.spr, b.spr); }
      else out.push({ t: k, o: b.o, h: b.h, l: b.l, c: b.c, spr: b.spr });
    }
    bars.length = 0; bars.push(...out);
  }
  return { sym: sym.slice(0, 6).toUpperCase(), digits, point, bars };
}

// same session rule as the live server (NY clock from server clock)
function windowOpen(t) {
  const ny = t - OFF * 3600; const d = new Date(ny * 1000);
  const wd = d.getUTCDay(); const h = d.getUTCHours() + d.getUTCMinutes() / 60;
  if (wd === 0 || wd === 6) return false;
  if (wd === 5 && h >= 16) return false;
  if (h >= 16 && h < 19) return false;
  return true;
}
const sessOf = (t) => { const h = TECH.nyHour(t, OFF); return (h >= 19 || h < 3) ? 'ASIA' : h < 8 ? 'LON' : h < 12 ? 'OVL' : 'NYPM'; };
// MT5 iATR = simple average of true range
function atrSMA(b, i, n = 14) {
  if (i < n) return 0; let s = 0;
  for (let k = i - n + 1; k <= i; k++) s += Math.max(b[k].h - b[k].l, Math.abs(b[k].h - b[k - 1].c), Math.abs(b[k].l - b[k - 1].c));
  return s / n;
}

// exit engine - mirrors server.js stepVirtual
function step(tr, b) {
  tr.bars++; const d = tr.dir;
  if (d > 0 ? b.l <= tr.sl : b.h >= tr.sl) return tr.sl;
  if (d > 0 ? b.h >= tr.tp : b.l <= tr.tp) return tr.tp;
  tr.maxFav = Math.max(tr.maxFav, d > 0 ? b.h - tr.entry : tr.entry - b.l);
  if (tr.maxFav >= X.be * tr.atr) tr.sl = d > 0 ? Math.max(tr.sl, tr.entry) : Math.min(tr.sl, tr.entry);
  if (tr.maxFav >= X.trailStart * tr.atr) { const ts = tr.entry + d * (tr.maxFav - X.trailDist * tr.atr); tr.sl = d > 0 ? Math.max(tr.sl, ts) : Math.min(tr.sl, ts); }
  if (tr.bars >= X.maxBars) return b.c;
  return null;
}

const files = fs.readdirSync(dir).filter(f => /\.csv$/i.test(f));
if (!files.length) { console.error('no csv files in', dir); process.exit(1); }
const trades = [];
const t0 = Date.now();
for (const f of files) {
  const P = load(path.join(dir, f)); const b = P.bars;
  const pip = P.sym.includes('JPY') ? 0.01 : 0.0001;
  const open = {};
  for (let i = WIN; i < b.length; i++) {
    for (const code of Object.keys(open)) {
      const tr = open[code]; const px = step(tr, b[i]);
      if (px !== null) {
        const R = ((px - tr.entry) * tr.dir) / (X.sl * tr.atr) - tr.costR;
        trades.push({ code, sym: P.sym, t: tr.t, R, sess: tr.sess, dir: tr.dir });
        delete open[code];
      }
    }
    if (!windowOpen(b[i].t)) continue;
    const atr = atrSMA(b, i); if (!(atr > 0)) continue;
    const cost = b[i].spr + COMM_PIPS * pip;
    if (b[i].spr / atr > 0.3) continue;
    const sigs = TECH.evalAll(b.slice(i - WIN + 1, i + 1), { offsetH: OFF });
    for (const s of sigs) {
      if (open[s.code]) continue;
      open[s.code] = { dir: s.dir, entry: b[i].c, atr, sl: b[i].c - s.dir * X.sl * atr, tp: b[i].c + s.dir * X.tp * atr,
        maxFav: 0, bars: 0, t: b[i].t, sess: sessOf(b[i].t), costR: cost / (X.sl * atr) };
    }
  }
  process.stderr.write(`${P.sym} bars ${b.length} trades so far ${trades.length} (${((Date.now() - t0) / 1000).toFixed(0)}s)\n`);
}

// ---------- report ----------
function stat(arr) {
  const n = arr.length; if (!n) return { n: 0 };
  const s = arr.reduce((a, x) => a + x, 0), m = s / n;
  const sd = Math.sqrt(arr.reduce((a, x) => a + (x - m) ** 2, 0) / Math.max(n - 1, 1));
  const gp = arr.filter(x => x > 0).reduce((a, x) => a + x, 0), gl = -arr.filter(x => x <= 0).reduce((a, x) => a + x, 0);
  return { n, sumR: +s.toFixed(1), avgR: +m.toFixed(3), t: +(m / (sd / Math.sqrt(n))).toFixed(2), win: +(100 * arr.filter(x => x > 0).length / n).toFixed(1), pf: gl ? +(gp / gl).toFixed(2) : 99 };
}
function dayT(list) { // t-stat on daily summed R (handles cross-pair clustering)
  const by = {}; for (const x of list) { const k = Math.floor((x.t - OFF * 3600 + 7 * 3600) / 86400); by[k] = (by[k] || 0) + x.R; }
  const v = Object.values(by); return stat(v).t;
}
const rows = [];
for (const code of TECH.CODES) {
  const L = trades.filter(x => x.code === code);
  const IS = L.filter(x => x.t < SPLIT), OOS = L.filter(x => x.t >= SPLIT);
  const years = {}; for (const x of L) { const y = new Date((x.t - OFF * 3600) * 1000).getUTCFullYear(); (years[y] = years[y] || []).push(x.R); }
  const sess = {}; for (const s of ['ASIA', 'LON', 'OVL', 'NYPM']) sess[s] = stat(L.filter(x => x.sess === s).map(x => x.R));
  const all = stat(L.map(x => x.R)), is = stat(IS.map(x => x.R)), oos = stat(OOS.map(x => x.R));
  const pass = is.n >= 100 && is.avgR > 0 && dayT(IS) >= 2.5 && oos.n >= 50 && oos.avgR > 0 && Object.values(years).every(a => stat(a).avgR > 0);
  rows.push({ code, name: TECH.BOOK_INFO[code].name, fam: TECH.BOOK_INFO[code].fam, all, is, oos, dayT_IS: dayT(IS), dayT_OOS: dayT(OOS),
    years: Object.fromEntries(Object.entries(years).map(([y, a]) => [y, stat(a)])), sess, pass });
}
rows.sort((a, b) => b.all.avgR - a.all.avgR);
const fmt = (s) => s.n ? `${s.avgR >= 0 ? '+' : ''}${s.avgR}R n${s.n} PF${s.pf}` : '-';
console.log(`\nMAXX FX SWARM technique lab backtest | ${files.length} pairs | split ${new Date(SPLIT * 1000).toISOString().slice(0, 10)} | offset ${OFF}h | commission ${COMM_PIPS} pip | TF ${TF}m | exits SL1/BE1/trail1.5/TP3/${X.maxBars} bars\n`);
for (const r of rows) {
  console.log(`${r.pass ? 'PASS' : '    '} ${r.name.padEnd(22)} [${r.fam}]  ALL ${fmt(r.all)} t${r.all.t} | IS ${fmt(r.is)} dayT ${r.dayT_IS} | OOS ${fmt(r.oos)} dayT ${r.dayT_OOS}`);
  console.log(`      years: ${Object.entries(r.years).map(([y, s]) => `${y} ${s.avgR >= 0 ? '+' : ''}${s.avgR}(${s.n})`).join('  ')} | sess: ${Object.entries(r.sess).map(([k, s]) => `${k} ${s.n ? (s.avgR >= 0 ? '+' : '') + s.avgR : '-'}`).join('  ')}`);
}
const outFile = path.join(dir, 'backtest_result.json');
fs.writeFileSync(outFile, JSON.stringify({ meta: { pairs: files.length, split: SPLIT, offset: OFF, comm: COMM_PIPS, exits: X }, rows }, null, 1));
fs.writeFileSync(path.join(dir, 'backtest_trades.csv'), 'code,sym,time,dir,sess,R\n' + trades.map(x => `${x.code},${x.sym},${x.t},${x.dir},${x.sess},${x.R.toFixed(4)}`).join('\n'));
console.log(`\nsaved ${outFile} + backtest_trades.csv (${trades.length} trades)`);
